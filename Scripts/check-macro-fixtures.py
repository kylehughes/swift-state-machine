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
        "import StateMachineSchema",
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


def captured(command):
    return subprocess.check_output(command, cwd=ROOT, text=True, timeout=120).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phases", type=int, default=128)
    parser.add_argument("--edges", type=int, default=512)
    parser.add_argument("--output", type=Path, help="Fresh evidence directory outside the package")
    parser.add_argument("--build-root", type=Path, help="Existing native SwiftPM binary directory containing Modules and StateMachineMacros-tool")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
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
    required = [modules / "StateMachine.swiftmodule", modules / "StateMachineSchema.swiftmodule", plugin]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        parser.error("Build StateMachineSchema with the native backend first; missing: " + ", ".join(missing))
    swiftc = captured(["xcrun", "--find", "swiftc"])
    sdk = captured(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    version = subprocess.check_output([swiftc, "--version"], cwd=ROOT, text=True, stderr=subprocess.STDOUT, timeout=120).strip()
    source = output / "MacroStressGraph.swift"
    source.write_text(generate_source(args.phases, args.edges, inputs["schema"]))
    object_file = output / "MacroStressGraph.o"
    command = [
        swiftc, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
        "-default-isolation", "nonisolated", "-target", "arm64-apple-macosx13.0", "-sdk", sdk,
        "-O" if args.configuration == "release" else "-Onone",
        "-I", str(modules), "-load-plugin-executable", f"{plugin}#StateMachineMacros",
        "-module-name", "MacroStressClient", "-c", str(source), "-o", str(object_file),
    ]
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
        "phases": args.phases,
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
