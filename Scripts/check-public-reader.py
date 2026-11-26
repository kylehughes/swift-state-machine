#!/usr/bin/env python3
"""Compare cross-module repeated Observed<Phase>.value field reads (`retained_multi_field`)
between two frozen Release closures across normal and -enable-library-evolution public schemas.

Diagnostic maintainer reproducer only; never a CI wall-clock gate."""

import argparse
import json
import math
from pathlib import Path
import platform
import statistics
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Probes/Performance/PublicReader"
sys.path.insert(0, str(ROOT / "Scripts"))
from performance_build import Evidence, digest, freeze_build, select_plan  # noqa: E402

MODES = ("normal", "library-evolution")


def compile_consumer(evidence: Evidence, side: str, mode: str, modules: Path, plugin: Path, objects: list[Path], sdk: str) -> Path:
    out_dir = evidence.directory / f"build-{side}-{mode}"
    out_dir.mkdir(parents=True, exist_ok=False)
    target = platform.machine() + "-apple-macosx13.0"
    common = [
        "xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
        "-default-isolation", "nonisolated", "-target", target, "-sdk", sdk, "-O", "-parse-as-library",
        "-module-cache-path", out_dir / "ModuleCache",
    ]
    schema_obj = out_dir / "PublicSchema.o"
    schema_cmd = [
        *common, "-I", modules, "-load-plugin-executable", f"{plugin}#StateMachineMacros",
        "-module-name", "PublicSchema", "-emit-module", "-emit-module-path", out_dir / "PublicSchema.swiftmodule",
    ]
    if mode == "library-evolution":
        schema_cmd += ["-enable-library-evolution", "-emit-module-interface-path", out_dir / "PublicSchema.swiftinterface"]
    evidence.run(f"{side}/{mode}/compile-schema", [*schema_cmd, "-c", FIXTURE / "Schema.swift", "-o", schema_obj])

    consumer_obj = out_dir / "PublicConsumer.o"
    evidence.run(
        f"{side}/{mode}/compile-consumer",
        [*common, "-I", modules, "-I", out_dir, "-module-name", "PublicConsumer", "-c", FIXTURE / "Consumer.swift", "-o", consumer_obj],
    )
    exe = out_dir / f"PublicReader-{side}-{mode}"
    evidence.run(
        f"{side}/{mode}/link",
        ["xcrun", "swiftc", "-target", target, "-sdk", sdk, "-Xlinker", "-dead_strip", consumer_obj, schema_obj, *objects, "-o", exe],
    )
    return exe


def run_once(evidence: Evidence, exe: Path, log_name: str, *, iterations: int, warmup: int, repetitions: int) -> dict:
    out = evidence.run(
        log_name,
        [exe, "--iterations", str(iterations), "--warmup", str(warmup), "--repetitions", str(repetitions)],
        timeout=300,
    )
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    if len(rows) != warmup + repetitions:
        raise ValueError(f"Expected {warmup + repetitions} rows from {exe.name}, got {len(rows)}")
    measured = [r for r in rows if r["warmup"] == 0]
    if len(measured) != repetitions or any(r["workload"] != "retained_multi_field" or r["wallNanoseconds"] <= 0 for r in measured):
        raise ValueError(f"Invalid measured rows from {exe.name}")
    checksums = {r["checksum"] for r in measured}
    if len(checksums) != 1:
        raise ValueError(f"Non-deterministic checksum from {exe.name}: {checksums}")
    ns_list = [r["nsPerOp"] for r in measured]
    return {"checksum": next(iter(checksums)), "medianNsPerOp": statistics.median(ns_list), "nsPerOp": ns_list}


def paired_compare(evidence: Evidence, mode: str, base_exe: Path, cand_exe: Path, *, rounds: int, iterations: int, warmup: int, repetitions: int) -> dict:
    round_rows = []
    for idx in range(rounds):
        order = ("baseline", "candidate") if idx % 2 == 0 else ("candidate", "baseline")
        pair = {
            side: run_once(
                evidence,
                base_exe if side == "baseline" else cand_exe,
                f"timing/{mode}/round-{idx:02d}-{side}",
                iterations=iterations, warmup=warmup, repetitions=repetitions,
            )
            for side in order
        }
        if pair["baseline"]["checksum"] != pair["candidate"]["checksum"]:
            raise ValueError(f"Checksum mismatch in {mode} round {idx}")
        round_rows.append({"round": idx, "order": list(order), **pair})

    b_vals = [r["baseline"]["medianNsPerOp"] for r in round_rows]
    c_vals = [r["candidate"]["medianNsPerOp"] for r in round_rows]
    ratios = sorted(c / b for b, c in zip(b_vals, c_vals))
    med = statistics.median(ratios)
    q25 = ratios[max(0, math.ceil(len(ratios) * 0.25) - 1)]
    q75 = ratios[max(0, math.ceil(len(ratios) * 0.75) - 1)]
    return {
        "workload": "retained_multi_field",
        "checksum": round_rows[0]["baseline"]["checksum"],
        "rounds": rounds,
        "iterations": iterations,
        "baselineMedianNsPerOp": statistics.median(b_vals),
        "candidateMedianNsPerOp": statistics.median(c_vals),
        "candidateOverBaselineTimeRatio": {
            "median": med,
            "mad": statistics.median(abs(x - med) for x in ratios),
            "iqr": q75 - q25,
            "min": ratios[0],
            "max": ratios[-1],
        },
        "noiseTreatment": "Paired interleaved AB/BA rounds with warmup and checksum parity; diagnostic only, not a CI gate.",
        "roundData": round_rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-closure", type=Path, required=True, help="Frozen baseline Release closure directory")
    parser.add_argument("--candidate-closure", type=Path, required=True, help="Frozen candidate Release closure directory")
    parser.add_argument("--output", type=Path, required=True, help="Fresh external evidence directory")
    parser.add_argument("--rounds", type=int, default=7, help="Paired interleaved AB/BA rounds (default: 7)")
    parser.add_argument("--iterations", type=int, default=250_000, help="Loop iterations per repetition (default: 250000)")
    parser.add_argument("--warmup", type=int, default=1, help="Warmup repetitions per invocation")
    parser.add_argument("--repetitions", type=int, default=3, help="Measured repetitions per invocation")
    args = parser.parse_args()
    if args.rounds < 1 or args.iterations < 64 or args.warmup < 0 or args.repetitions < 1:
        parser.error("Invalid benchmark dimensions")
    output = args.output.resolve()
    if output.is_relative_to(ROOT):
        parser.error("--output must be outside the package")
    output.mkdir(parents=True, exist_ok=False)

    evidence = Evidence(output, ROOT)
    status = {"status": "running", "results": {}}
    save = lambda: (output / "results.json").write_text(json.dumps(status, indent=2) + "\n")
    save()
    try:
        sdk = evidence.run("environment/sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-path"], timeout=120).strip()
        manifest = json.loads(evidence.run(
            "environment/package", ["swift", "package", "--scratch-path", output / "swiftpm-manifest", "dump-package"], timeout=120
        ))
        closures = {}
        for side, path in (("baseline", args.baseline_closure.resolve()), ("candidate", args.candidate_closure.resolve())):
            commands = select_plan(path, manifest)
            closures[side] = freeze_build(path, commands, output / f"{side}-closure")
        status["closures"] = {"baseline": str(args.baseline_closure.resolve()), "candidate": str(args.candidate_closure.resolve())}

        for mode in MODES:
            base_exe = compile_consumer(evidence, "baseline", mode, *closures["baseline"], sdk)
            cand_exe = compile_consumer(evidence, "candidate", mode, *closures["candidate"], sdk)
            paired = paired_compare(
                evidence, mode, base_exe, cand_exe,
                rounds=args.rounds, iterations=args.iterations, warmup=args.warmup, repetitions=args.repetitions,
            )
            paired["binaries"] = {
                "baseline": {"path": str(base_exe), "sha256": digest(base_exe)},
                "candidate": {"path": str(cand_exe), "sha256": digest(cand_exe)},
            }
            status["results"][mode] = paired
            save()
            r = paired["candidateOverBaselineTimeRatio"]
            print(
                f"{mode:17s} retained_multi_field: baseline={paired['baselineMedianNsPerOp']:6.2f} ns/op  "
                f"candidate={paired['candidateMedianNsPerOp']:6.2f} ns/op  "
                f"ratio={r['median']:.3f}x (min={r['min']:.3f}x max={r['max']:.3f}x)"
            )
        status["status"] = "pass"
        save()
        print(f"PASS: evidence={output}")
        return 0
    except Exception as error:
        status["status"] = "fail"
        status["error"] = str(error)
        save()
        print(f"ERROR: {error}; evidence={output}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
