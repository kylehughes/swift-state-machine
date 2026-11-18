#!/usr/bin/env python3
"""Compile a deterministic generated macro graph and retain external compiler evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / "ClientFixtures/MacroStress/graphs.json"
TIMEOUT_SECONDS = 600


def generate_source(phases, edges, name):
    """Create unique (source, trigger) pairs, reusing one input per phase-sized group."""
    lines = [
        "import StateMachine",
        "",
        "@StateMachine(mode: .shared)",
        f"nonisolated enum {name}: Sendable {{",
    ]
    for phase in range(phases):
        lines.append(f"    struct Phase{phase}: Sendable {{ let value: Int }}")
    for phase in range(phases):
        lines.append(f"    {'@Initial ' if phase == 0 else ''}case phase{phase}(Phase{phase})")
    lines.append("    enum Input: Sendable {")
    for group in range((edges + phases - 1) // phases):
        lines.append(f"        case event{group}")
    lines.append("    }")
    for edge in range(edges):
        source = edge % phases
        destination = (source + 1) % phases
        group = edge // phases
        lines.extend([
            f"    @Transition(on: Input.event{group})",
            f"    fileprivate static func step{edge}(_ source: Phase{source}) -> Phase{destination} {{",
            f"        Phase{destination}(value: source.value + 1)",
            "    }",
        ])
    lines.extend(["}", ""])
    return "\n".join(lines)


def generate_sparse_source(phases, edges, name):
    """Create edges that each use their own input case, so most (input, phase) pairs have no edge."""
    lines = [
        "import StateMachine",
        "",
        "@StateMachine(mode: .shared)",
        f"nonisolated enum {name}: Sendable {{",
    ]
    for phase in range(phases):
        lines.append(f"    struct Phase{phase}: Sendable {{ let value: Int }}")
    for phase in range(phases):
        lines.append(f"    {'@Initial ' if phase == 0 else ''}case phase{phase}(Phase{phase})")
    lines.append("    enum Input: Sendable {")
    for edge in range(edges):
        lines.append(f"        case event{edge}")
    lines.append("    }")
    for edge in range(edges):
        source = edge % phases
        destination = (source + 1) % phases
        lines.extend([
            f"    @Transition(on: Input.event{edge})",
            f"    fileprivate static func step{edge}(_ source: Phase{source}) -> Phase{destination} {{",
            f"        Phase{destination}(value: source.value + 1)",
            "    }",
        ])
    lines.extend(["}", ""])
    return "\n".join(lines)


def generate_operation_source(phases, operations, span, name):
    """Create a ring on one input plus operations, each active in `span` consecutive phases."""
    stride = max(1, phases // operations)
    lines = [
        "import StateMachine",
        "",
        "@StateMachine(mode: .shared)",
        f"nonisolated enum {name}: Sendable {{",
        "    enum Problem: Error, Sendable { case failed }",
        f"    enum Scope {{ case {', '.join(f'work{op}' for op in range(operations))} }}",
    ]
    for phase in range(phases):
        lines.append(f"    struct Phase{phase}: Sendable {{ let value: Int }}")
    for phase in range(phases):
        lines.append(f"    {'@Initial ' if phase == 0 else ''}case phase{phase}(Phase{phase})")
    lines.append("    enum Input: Sendable {")
    lines.append("        case next, start")
    lines.append("    }")
    for op in range(operations):
        active = [(op * stride + offset) % phases for offset in range(span)]
        lines.extend([
            f"    @Operation(scope: Scope.work{op}, activeIn: [{', '.join(f'Phase{p}.self' for p in active)}], admission: .latest)",
            f"    enum Op{op} {{",
            "        typealias Input = Int",
            "        typealias Output = Int",
            f"        typealias Failure = {'Problem' if op % 2 == 0 else 'Never'}",
            "    }",
        ])
    for phase in range(phases):
        lines.extend([
            "    @Transition(on: Input.next)",
            f"    fileprivate static func next{phase}(_ source: Phase{phase}) -> Phase{(phase + 1) % phases} {{",
            f"        Phase{(phase + 1) % phases}(value: source.value + 1)",
            "    }",
        ])
    for op in range(operations):
        first = (op * stride) % phases
        lines.extend([
            f"    @Transition(on: Input.start, starts: [Op{op}.self])",
            f"    fileprivate static func start{op}(_ source: Phase{first}) -> Change<Phase{first}, Effect.Start{op}> {{",
            f"        Change(source, effects: [.op{op}(source.value)])",
            "    }",
        ])
        for offset in range(span):
            phase = (op * stride + offset) % phases
            lines.extend([
                f"    @Transition(onSuccess: Op{op}.self)",
                f"    fileprivate static func done{op}in{phase}(_ source: Phase{phase}, _ output: Op{op}.Output) -> Phase{phase} {{",
                "        source",
                "    }",
            ])
            if op % 2 == 0:
                lines.extend([
                    f"    @Transition(onFailure: Op{op}.self)",
                    f"    fileprivate static func fail{op}in{phase}(_ source: Phase{phase}, _ reason: Op{op}.Failure) -> Phase{phase} {{",
                    "        source",
                    "    }",
                ])
    lines.extend(["}", ""])
    return "\n".join(lines)


def captured(command):
    return subprocess.check_output(command, cwd=ROOT, text=True, timeout=120).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phases", type=int, help="Phase count (default: the variant's, else 128)")
    parser.add_argument("--edges", type=int, help="Edge count (default: the variant's, else 512)")
    parser.add_argument("--variant", choices=("dense", "sparse-input", "operation-heavy"), default="dense",
                        help="dense is the default graph; the others use the shapes in graphs.json under variants")
    parser.add_argument("--operations", type=int, help="Override the operation count of the operation-heavy variant")
    parser.add_argument("--keep-expansions", action="store_true", help="Also retain the compiler's macro expansion text")
    parser.add_argument("--output", type=Path, help="Fresh evidence directory outside the package")
    parser.add_argument("--build-root", type=Path, help="Existing native SwiftPM binary directory containing Modules and StateMachineMacros-tool")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    shape = json.loads(INPUTS.read_text()).get("variants", {}).get(args.variant, {})
    if args.phases is None:
        args.phases = shape.get("phases", 128)
    if args.edges is None:
        args.edges = shape.get("edges", 512)
    if args.phases < 1 or args.edges < 0:
        parser.error("--phases must be positive and --edges must be nonnegative")
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="atomic-macro-stress-"))
    if output.is_relative_to(ROOT):
        parser.error("--output must be outside the package to keep candidate evidence separate")
    if (output / "results.json").exists():
        parser.error("--output already contains results.json; choose a fresh evidence directory")
    output.mkdir(parents=True, exist_ok=True)
    inputs = json.loads(INPUTS.read_text())
    build_root = args.build_root.resolve() if args.build_root else Path(captured([
        "swift", "build", "--build-system", "native", "--configuration", args.configuration, "--show-bin-path",
    ]))
    modules = build_root / "Modules"
    plugin = build_root / "StateMachineMacros-tool"
    required = [modules / "StateMachine.swiftmodule", plugin]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        parser.error("Build StateMachine with the native backend first; missing: " + ", ".join(missing))
    swiftc = captured(["xcrun", "--find", "swiftc"])
    sdk = captured(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    version = subprocess.check_output([swiftc, "--version"], cwd=ROOT, text=True, stderr=subprocess.STDOUT, timeout=120).strip()
    source = output / "MacroStressGraph.swift"
    graph_inputs, graph_operations = (args.edges if args.variant == "sparse-input" else (args.edges + args.phases - 1) // args.phases), 0
    if args.variant == "sparse-input":
        source.write_text(generate_sparse_source(args.phases, args.edges, inputs["schema"]))
    elif args.variant == "operation-heavy":
        shape = inputs["variants"]["operation-heavy"]
        operations = args.operations if args.operations is not None else shape["operations"]
        span = shape["operationSpan"]
        graph_inputs, graph_operations = 2, operations
        args.edges = args.phases + operations + operations * span + (operations + 1) // 2 * span
        source.write_text(generate_operation_source(args.phases, operations, shape["operationSpan"], inputs["schema"]))
    else:
        source.write_text(generate_source(args.phases, args.edges, inputs["schema"]))
    object_file = output / "MacroStressGraph.o"
    command = [
        swiftc, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
        "-default-isolation", "nonisolated", "-target", "arm64-apple-macosx13.0", "-sdk", sdk,
        "-O" if args.configuration == "release" else "-Onone",
        "-I", str(modules), "-load-plugin-executable", f"{plugin}#StateMachineMacros",
        "-module-name", "MacroStressClient", "-c", str(source), "-o", str(object_file),
    ]
    if args.keep_expansions:
        command += ["-Xfrontend", "-dump-macro-expansions"]
    resources = output / "resources.log"
    measured_command = ["/usr/bin/time", "-l", "-o", str(resources), *command]
    (output / "command.json").write_text(json.dumps(measured_command, indent=2) + "\n")
    started = time.monotonic()
    with (output / "compile.log").open("w") as log:
        process = subprocess.Popen(measured_command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            exit_code = process.wait(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            exit_code = process.wait()
    duration = time.monotonic() - started
    resource_text = resources.read_text() if resources.exists() else ""
    peak_rss = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", resource_text, re.M)
    status = "timeout" if timed_out else "pass" if exit_code == 0 and object_file.exists() else "fail"
    results = {
        "status": status,
        "variant": args.variant,
        "phases": args.phases,
        "inputs": graph_inputs,
        "operations": graph_operations,
        "edges": args.edges,
        "configuration": args.configuration,
        "duration_seconds": duration,
        "timeout_seconds": TIMEOUT_SECONDS,
        "exit_code": exit_code,
        "command": command,
        "measured_command": measured_command,
        "toolchain": version,
        "sdk": sdk,
        "build_root": str(build_root),
        "source": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "graph_inputs": inputs,
        "plugin_sha256": hashlib.sha256(plugin.read_bytes()).hexdigest(),
        "module_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in required[:-1]},
        "object_bytes": object_file.stat().st_size if object_file.exists() else None,
        "maximum_resident_set_size_bytes": int(peak_rss.group(1)) if peak_rss else None,
        "resource_log": str(resources),
        "compile_log": str(output / "compile.log"),
        "limitations": ["Compiles the generated client; does not execute it or establish minimum-OS execution."],
    }
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"{status}: {args.phases} phases / {args.edges} edges in {duration:.3f}s; evidence: {output}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
