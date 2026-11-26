#!/usr/bin/env python3
"""Gate live arm64 __TEXT,__text value-witness bytes on a representative 9-phase .isolated .local consumer,
with optional paired interleaved throughput comparison against a frozen baseline closure."""

import argparse
import collections
import json
import math
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WITNESS_FIXTURE = ROOT / "Probes/Performance/WitnessSize"
sys.path.insert(0, str(ROOT / "Scripts"))
from performance_build import Evidence, digest, freeze_build, select_plan  # noqa: E402

SCHEMA_TOKEN = "DocumentSyncFlow"
# Default byte budgets for live arm64 __TEXT,__text value-witness + outlined helper bytes.
# 1. Schema-attributed scope (`DocumentSyncFlow` in demangled symbol): 256 KiB (262,144 B).
#    Observed reference run on macOS arm64 Swift 6.4: cb99e745 = 1,376,400 B; candidate = 140,672 B.
DEFAULT_BUDGET_BYTES = 256 * 1024
# 2. Whole-executable live __TEXT,__text witness+helper scope (all live symbols): 512 KiB (524,288 B).
#    Prevents moving generated witness symbols out of the schema namespace from masking a regression.
#    Observed reference run on macOS arm64 Swift 6.4: cb99e745 = 1,576,904 B; candidate = 250,316 B.
DEFAULT_ALL_WITNESS_BUDGET_BYTES = 512 * 1024


def evaluate_budgets(macho: dict, schema_budget: int, all_budget: int) -> dict:
    """Evaluate both schema-scoped and whole-executable live __TEXT,__text witness+helper budgets."""
    schema_bytes = macho["schema"]["combinedWitnessAndHelperBytes"]
    all_bytes = macho["allLiveText"]["combinedWitnessAndHelperBytes"]
    schema_pass = schema_bytes <= schema_budget
    all_pass = all_bytes <= all_budget
    failures = []
    if not schema_pass:
        failures.append(
            f"schema.combinedWitnessAndHelperBytes ({schema_bytes} B) > schema budget ({schema_budget} B)"
        )
    if not all_pass:
        failures.append(
            f"allLiveText.combinedWitnessAndHelperBytes ({all_bytes} B) > all-witness budget ({all_budget} B)"
        )
    return {
        "passed": schema_pass and all_pass,
        "schemaBudgetPassed": schema_pass,
        "schemaBudgetBytes": schema_budget,
        "schemaMarginBytes": schema_budget - schema_bytes,
        "allWitnessBudgetPassed": all_pass,
        "allWitnessBudgetBytes": all_budget,
        "allWitnessMarginBytes": all_budget - all_bytes,
        "failures": failures,
    }


def source_identities() -> dict[str, str]:
    paths = [ROOT / "Package.swift", ROOT / "Package.resolved", Path(__file__), ROOT / "Scripts/performance_build.py"]
    paths += [p for name in ("StateMachine", "StateMachineMacros") for p in sorted((ROOT / "Sources" / name).rglob("*.swift"))]
    paths += sorted(WITNESS_FIXTURE.rglob("*.swift"))
    return {str(p.relative_to(ROOT)): digest(p) for p in paths if p.is_file()}

OUTLINED_RE = re.compile(r"^(?:merged )?outlined ")
SECTION_RE = re.compile(r"^(0x[\dA-Fa-f]+)\s+(0x[\dA-Fa-f]+)\s+__TEXT\s+__text$")
SYMBOL_RE = re.compile(r"^(0x[\dA-Fa-f]+)\s+(0x[\dA-Fa-f]+)\s+\[\s*\d+\]\s+(.+)$")
SIZE_TEXT_RE = re.compile(r"Section (?:\(__TEXT, ?__text\)|__text):\s*(\d+)")


def extent_bytes(extents: dict[int, int]) -> int:
    """Return exact union byte length of {start: size} intervals, preventing alias double-counting."""
    end = total = 0
    for start, length in sorted(extents.items()):
        total += max(0, start + length - max(end, start))
        end = max(end, start + length)
    return total


def demangle_batch(names: list[str]) -> list[str]:
    if not names:
        raise ValueError("No live symbols to demangle")
    proc = subprocess.run(
        ["xcrun", "swift-demangle", "--compact"],
        input="\n".join(names) + "\n",
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"swift-demangle failed ({proc.returncode}): {proc.stderr.strip()}")
    lines = proc.stdout.splitlines()
    if len(lines) != len(names):
        raise ValueError(f"swift-demangle line count mismatch: {len(lines)} != {len(names)}")
    return lines


def parse_link_map(link_map_text: str, size_output: str, file_bytes: int, demangler=demangle_batch) -> dict:
    """Parse live __TEXT,__text symbol extents from ld -map and cross-check against `size -m`."""
    lines = link_map_text.splitlines()
    arch_line = next((line for line in lines if line.startswith("# Arch:")), None)
    if arch_line is None or "arm64" not in arch_line:
        raise ValueError(f"Missing or non-arm64 # Arch header in linker map: {arch_line!r}")

    text_matches = [SECTION_RE.match(line.strip()) for line in lines]
    text_matches = [m for m in text_matches if m is not None]
    if len(text_matches) != 1:
        raise ValueError(f"Expected exactly 1 __TEXT __text section in linker map, found {len(text_matches)}")
    text_start, text_length = (int(x, 16) for x in text_matches[0].groups())
    if text_length <= 0:
        raise ValueError(f"Non-positive __TEXT __text length: {text_length}")

    size_match = SIZE_TEXT_RE.search(size_output)
    if size_match is None:
        raise ValueError("Missing __TEXT,__text section in `xcrun size -m` output")
    binary_text = int(size_match.group(1))
    if binary_text != text_length:
        raise ValueError(f"Mach-O __TEXT,__text mismatch: size -m={binary_text} != link map={text_length}")

    if "# Symbols:" not in lines:
        raise ValueError("Missing # Symbols: section in linker map")
    live_lines = lines[lines.index("# Symbols:") + 1 :]
    dead_index = next((i for i, line in enumerate(live_lines) if line.startswith("# Dead Stripped")), len(live_lines))

    records = []
    for line in live_lines[:dead_index]:
        m = SYMBOL_RE.match(line)
        if m is None:
            continue
        addr, size = int(m.group(1), 16), int(m.group(2), 16)
        name = m.group(3)
        if size > 0 and text_start <= addr and addr + size <= text_start + text_length:
            records.append((addr, size, name))
    if not records:
        raise ValueError("No live __TEXT,__text symbols found before # Dead Stripped")

    demangled = demangler([name for _, _, name in records])
    if len(demangled) != len(records):
        raise ValueError("Demangled symbol count mismatch")

    def empty_bucket():
        return {"text": {}, "witness": {}, "outlined": {}, "combined": {}, "kinds": collections.Counter()}

    buckets = {"schema": empty_bucket(), "allLiveText": empty_bucket()}
    top_schema_witness = []
    aliases = collections.Counter()

    for (addr, size, sym), desc in zip(records, demangled):
        aliases[addr] += 1
        is_witness = (" value witness for " in desc) and (" value witness table for " not in desc)
        is_outlined = (not is_witness) and bool(OUTLINED_RE.match(desc))
        is_schema = SCHEMA_TOKEN in desc

        targets = [buckets["allLiveText"]]
        if is_schema:
            targets.append(buckets["schema"])

        for bucket in targets:
            bucket["text"][addr] = max(bucket["text"].get(addr, 0), size)
            if is_witness:
                if addr not in bucket["witness"]:
                    bucket["kinds"][desc.split(" value witness for ")[0]] += size
                bucket["witness"][addr] = max(bucket["witness"].get(addr, 0), size)
                bucket["combined"][addr] = max(bucket["combined"].get(addr, 0), size)
            elif is_outlined:
                if addr not in bucket["outlined"]:
                    bucket["kinds"]["outlined"] += size
                bucket["outlined"][addr] = max(bucket["outlined"].get(addr, 0), size)
                bucket["combined"][addr] = max(bucket["combined"].get(addr, 0), size)

        if is_schema and (is_witness or is_outlined):
            top_schema_witness.append(
                {"address": hex(addr), "bytes": size, "kind": "value_witness" if is_witness else "outlined", "symbol": desc}
            )

    def summarize_bucket(bucket):
        witness_b = extent_bytes(bucket["witness"])
        outlined_b = extent_bytes(bucket["outlined"])
        combined_b = extent_bytes(bucket["combined"])
        text_b = extent_bytes(bucket["text"])
        return {
            "attributedTextBytes": text_b,
            "valueWitnessBytes": witness_b,
            "outlinedHelperBytes": outlined_b,
            "combinedWitnessAndHelperBytes": combined_b,
            "combinedShareOfLiveText": combined_b / text_length,
            "witnessKinds": dict(bucket["kinds"].most_common()),
        }

    schema_summary = summarize_bucket(buckets["schema"])
    all_summary = summarize_bucket(buckets["allLiveText"])
    if schema_summary["attributedTextBytes"] <= 0 or schema_summary["valueWitnessBytes"] <= 0:
        raise ValueError(f"Missing or dead-stripped {SCHEMA_TOKEN} witness attribution in live __TEXT,__text")

    top_schema_witness.sort(key=lambda r: (-r["bytes"], r["address"]))
    return {
        "architecture": "arm64",
        "liveTextBytes": text_length,
        "liveTextVmAddr": hex(text_start),
        "liveSymbolRecords": len(records),
        "aliasedAddresses": sum(1 for count in aliases.values() if count > 1),
        "machOFileBytes": file_bytes,
        "machOFileBytesNote": "Whole Mach-O file size on disk; distinct from live __TEXT,__text and not gated.",
        "schema": schema_summary,
        "allLiveText": all_summary,
        "topSchemaWitnessSymbols": top_schema_witness[:20],
    }


def compile_and_measure(evidence: Evidence, label: str, modules: Path, plugin: Path, objects: list[Path], sdk: str) -> tuple[Path, dict, dict]:
    sources = [WITNESS_FIXTURE / "Domain.swift", WITNESS_FIXTURE / "Main.swift"]
    exe = evidence.directory / f"WitnessSize-{label}"
    link_map = evidence.directory / f"WitnessSize-{label}-linkmap.txt"
    evidence.run(
        f"{label}/compile",
        [
            "xcrun", "swiftc",
            "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
            "-default-isolation", "nonisolated",
            "-target", platform.machine() + "-apple-macosx13.0", "-sdk", sdk,
            "-O", "-parse-as-library",
            "-I", modules,
            "-load-plugin-executable", f"{plugin}#StateMachineMacros",
            "-module-name", "StateMachineWitnessSize",
            "-module-cache-path", evidence.directory / f"{label}-ModuleCache",
            "-Xlinker", "-dead_strip",
            "-Xlinker", "-map", "-Xlinker", link_map,
            *sources, *objects, "-o", exe,
        ],
    )
    verify_out = evidence.run(f"{label}/verify", [exe, "--mode", "verify", "--cycles", "16", "--seed", "42"], timeout=120)
    verify_lines = [l for l in verify_out.splitlines() if l.strip()]
    if len(verify_lines) != 1:
        raise ValueError(f"Expected 1 verification JSON line, got {len(verify_lines)}")
    verify = json.loads(verify_lines[0])
    if verify.get("distinctPhasesVisited") != 9 or verify.get("cycles") != 16 or verify.get("rejectionsObserved") != 16:
        raise ValueError(f"Verification invariant mismatch: {verify}")
    size_out = evidence.run(f"{label}/size-m", ["xcrun", "size", "-m", "-arch", "arm64", exe], timeout=60)
    macho = parse_link_map(link_map.read_text(), size_out, exe.stat().st_size)
    macho["binarySHA256"] = digest(exe)
    macho["linkMap"] = str(link_map)
    return exe, verify, macho


def run_benchmark(evidence: Evidence, exe: Path, log_name: str, *, cycles: int, warmup: int, repetitions: int, seed: int) -> dict:
    out = evidence.run(
        log_name,
        [exe, "--mode", "benchmark", "--cycles", str(cycles), "--warmup", str(warmup),
         "--repetitions", str(repetitions), "--seed", str(seed)],
        timeout=300,
    )
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    if len(rows) != warmup + repetitions:
        raise ValueError(f"Expected {warmup + repetitions} benchmark rows, got {len(rows)}")
    measured = [r for i, r in enumerate(rows) if i >= warmup]
    if any(r.get("warmup") != 0 or r.get("distinctPhasesVisited") != 9 or r.get("wallNanoseconds", 0) <= 0 for r in measured):
        raise ValueError("Invalid measured benchmark row")
    checksums = {r["checksum"] for r in measured}
    transitions = {r["transitions"] for r in measured}
    if len(checksums) != 1 or len(transitions) != 1:
        raise ValueError("Non-deterministic benchmark checksum or transition count")
    median_ns = statistics.median(r["wallNanoseconds"] for r in measured)
    return {
        "cycles": cycles,
        "transitions": next(iter(transitions)),
        "checksum": next(iter(checksums)),
        "measuredWallNanoseconds": [r["wallNanoseconds"] for r in measured],
        "medianWallNanoseconds": median_ns,
        "transitionsPerSecond": next(iter(transitions)) / (median_ns / 1e9),
    }


def summarize_paired(rounds: list[dict]) -> dict:
    if not rounds:
        raise ValueError("No paired throughput rounds")
    ratios = [r["candidateOverBaselineThroughputRatio"] for r in rounds]
    ordered = sorted(ratios)
    q25 = ordered[max(0, math.ceil(len(ordered) * 0.25) - 1)]
    q75 = ordered[max(0, math.ceil(len(ordered) * 0.75) - 1)]
    med = statistics.median(ratios)
    return {
        "rounds": len(rounds),
        "baselineMedianTransitionsPerSecond": statistics.median(r["baseline"]["transitionsPerSecond"] for r in rounds),
        "candidateMedianTransitionsPerSecond": statistics.median(r["candidate"]["transitionsPerSecond"] for r in rounds),
        "candidateOverBaselineThroughputRatio": {
            "median": med,
            "mad": statistics.median(abs(x - med) for x in ratios),
            "iqr": q75 - q25,
            "min": min(ratios),
            "max": max(ratios),
        },
        "noiseTreatment": (
            "Paired interleaved AB/BA rounds cancel thermal/load drift; each process runs full warmup "
            "and checks deterministic checksums. Diagnostic only; never a single-sample CI gate."
        ),
    }


def obtain_closure(evidence: Evidence, manifest: dict, output: Path, label: str, build_root, reuse_build_root, scratch_path):
    if reuse_build_root is not None:
        resolved = reuse_build_root.resolve()
        commands = select_plan(resolved, manifest)
        reused = True
    else:
        scratch = scratch_path.resolve() if scratch_path else (build_root.resolve().parent.parent if build_root else output / f"{label}-swiftpm")
        evidence.run(
            f"{label}/build-native-release",
            ["swift", "build", "--build-system", "native", "--configuration", "release", "--scratch-path", scratch, "--target", "StateMachine"],
        )
        resolved = build_root.resolve() if build_root else scratch / (platform.machine() + "-apple-macosx") / "release"
        commands = select_plan(resolved, manifest)
        reused = False
    modules, plugin, objects = freeze_build(resolved, commands, output / f"{label}-closure")
    return resolved, reused, modules, plugin, objects


def run_paired_throughput(
    evidence: Evidence,
    base_exe: Path,
    cand_exe: Path,
    *,
    rounds_count: int,
    cycles: int,
    warmup: int,
    repetitions: int,
    base_seed: int,
) -> dict:
    """Run paired interleaved AB/BA warmed throughput rounds and verify deterministic parity."""
    rounds = []
    for idx in range(rounds_count):
        seed = base_seed + idx
        order = ("baseline", "candidate") if idx % 2 == 0 else ("candidate", "baseline")
        pair = {}
        for which in order:
            pair[which] = run_benchmark(
                evidence,
                base_exe if which == "baseline" else cand_exe,
                f"throughput/round-{idx:02d}-{which}",
                cycles=cycles,
                warmup=warmup,
                repetitions=repetitions,
                seed=seed,
            )
        if (pair["baseline"]["checksum"], pair["baseline"]["transitions"]) != (
            pair["candidate"]["checksum"],
            pair["candidate"]["transitions"],
        ):
            raise ValueError(f"Throughput parity mismatch on round {idx}")
        rounds.append({
            "round": idx,
            "seed": seed,
            "order": list(order),
            "baseline": pair["baseline"],
            "candidate": pair["candidate"],
            "candidateOverBaselineThroughputRatio": (
                pair["candidate"]["transitionsPerSecond"] / pair["baseline"]["transitionsPerSecond"]
            ),
        })
    return {
        "cycles": cycles,
        "warmup": warmup,
        "repetitions": repetitions,
        "summary": summarize_paired(rounds),
        "rounds": rounds,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Fresh evidence directory outside the package")
    parser.add_argument("--build-root", type=Path, help="Native Release bin directory (builds StateMachine first)")
    parser.add_argument("--reuse-build-root", type=Path, help="Frozen shipping closure or Release bin directory (skips build)")
    parser.add_argument("--scratch-path", type=Path, help="Optional SwiftPM scratch path")
    parser.add_argument(
        "--budget-bytes",
        type=int,
        default=DEFAULT_BUDGET_BYTES,
        help=f"Max schema-attributed live __TEXT,__text witness+outlined bytes (default: {DEFAULT_BUDGET_BYTES})",
    )
    parser.add_argument(
        "--all-witness-budget-bytes",
        type=int,
        default=DEFAULT_ALL_WITNESS_BUDGET_BYTES,
        help=f"Max whole-executable live __TEXT,__text witness+outlined bytes (default: {DEFAULT_ALL_WITNESS_BUDGET_BYTES})",
    )
    parser.add_argument("--compare-baseline", type=Path, help="Frozen baseline closure for paired size + throughput comparison")
    parser.add_argument(
        "--paired-executables",
        nargs=2,
        type=Path,
        metavar=("BASELINE_EXE", "CANDIDATE_EXE"),
        help="Run paired interleaved throughput comparison directly on two pre-staged executables",
    )
    parser.add_argument("--rounds", type=int, default=9, help="Paired interleaved rounds (default: 9)")
    parser.add_argument("--cycles", type=int, default=800, help="Workflow cycles per benchmark repetition (default: 800)")
    parser.add_argument("--warmup", type=int, default=1, help="Warmup repetitions per invocation")
    parser.add_argument("--repetitions", type=int, default=1, help="Measured repetitions per invocation")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic base seed")
    parser.add_argument("--skip-throughput", action="store_true", help="Compare size and functional parity only")
    args = parser.parse_args()

    if args.budget_bytes <= 0 or args.all_witness_budget_bytes <= 0 or (args.build_root and args.reuse_build_root):
        parser.error("Invalid budgets or conflicting build-root options")
    if args.paired_executables and (args.compare_baseline or args.build_root or args.reuse_build_root):
        parser.error("--paired-executables cannot be combined with build-root or --compare-baseline options")
    output = args.output.resolve()
    if output.is_relative_to(ROOT):
        parser.error("--output must be outside the package")
    output.mkdir(parents=True, exist_ok=False)

    evidence = Evidence(output, ROOT)
    initial_identity = source_identities()
    status = {
        "status": "running",
        "budgets": {
            "schemaCombinedWitnessAndHelperBytes": {
                "limitBytes": args.budget_bytes,
                "metric": "schema.combinedWitnessAndHelperBytes",
                "scope": f"Live arm64 __TEXT,__text value-witness and outlined helper intervals attributed to `{SCHEMA_TOKEN}`.",
            },
            "allLiveTextCombinedWitnessAndHelperBytes": {
                "limitBytes": args.all_witness_budget_bytes,
                "metric": "allLiveText.combinedWitnessAndHelperBytes",
                "scope": "All live arm64 __TEXT,__text value-witness and outlined helper intervals across the entire linked fixture executable.",
            },
        },
        "sourceIdentity": initial_identity,
        "limitations": [
            "Representative 9-phase .isolated .local macOS arm64 consumer linked with -O -dead_strip.",
            "Live __TEXT,__text witness+helper bytes are distinct from whole Mach-O file size and iOS app size.",
        ],
    }

    def save():
        (output / "results.json").write_text(json.dumps(status, indent=2) + "\n")

    save()
    try:
        for env_name, env_cmd in (
            ("swift-version", ["xcrun", "swift", "--version"]),
            ("xcode-version", ["xcodebuild", "-version"]),
            ("os", ["sw_vers"]),
            ("git-head", ["git", "rev-parse", "--verify", "HEAD"]),
        ):
            evidence.run("environment/" + env_name, env_cmd, timeout=60, allow_failure=(env_name == "git-head"))

        if args.paired_executables:
            base_exe, cand_exe = (p.resolve() for p in args.paired_executables)
            for exe in (base_exe, cand_exe):
                if not exe.is_file():
                    raise ValueError(f"Staged executable missing: {exe}")
            status["pairedExecutables"] = {
                "baseline": {"path": str(base_exe), "sha256": digest(base_exe)},
                "candidate": {"path": str(cand_exe), "sha256": digest(cand_exe)},
            }
            status["throughputComparison"] = run_paired_throughput(
                evidence,
                base_exe,
                cand_exe,
                rounds_count=args.rounds,
                cycles=args.cycles,
                warmup=args.warmup,
                repetitions=args.repetitions,
                base_seed=args.seed,
            )
            status["status"] = "pass"
            save()
            med = status["throughputComparison"]["summary"]["candidateOverBaselineThroughputRatio"]["median"]
            print(f"PASS (paired throughput): median candidate/baseline={med:.4f}x over {args.rounds} rounds; evidence: {output}")
            return 0

        sdk = evidence.run("environment/sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-path"], timeout=120).strip()
        manifest_scratch = args.scratch_path.resolve() if args.scratch_path else (
            args.build_root.resolve().parent.parent if args.build_root else output / "swiftpm-manifest"
        )
        manifest = json.loads(evidence.run(
            "environment/package", ["swift", "package", "--scratch-path", manifest_scratch, "dump-package"], timeout=120
        ))

        c_root, c_reused, c_mod, c_plug, c_obj = obtain_closure(
            evidence, manifest, output, "candidate", args.build_root, args.reuse_build_root, args.scratch_path
        )
        c_exe, c_verify, c_macho = compile_and_measure(evidence, "candidate", c_mod, c_plug, c_obj, sdk)
        c_eval = evaluate_budgets(c_macho, args.budget_bytes, args.all_witness_budget_bytes)
        c_schema_bytes = c_macho["schema"]["combinedWitnessAndHelperBytes"]
        c_all_bytes = c_macho["allLiveText"]["combinedWitnessAndHelperBytes"]
        status["candidate"] = {
            "buildRoot": str(c_root),
            "reusedBuildRoot": c_reused,
            "executablePath": str(c_exe),
            "verification": c_verify,
            "machO": c_macho,
            "budgetEvaluation": c_eval,
        }
        save()

        if args.compare_baseline:
            b_root, _, b_mod, b_plug, b_obj = obtain_closure(
                evidence, manifest, output, "baseline", None, args.compare_baseline, None
            )
            b_exe, b_verify, b_macho = compile_and_measure(evidence, "baseline", b_mod, b_plug, b_obj, sdk)
            if (b_verify["checksum"], b_verify["transitions"]) != (c_verify["checksum"], c_verify["transitions"]):
                raise ValueError("Functional verification mismatch between baseline and candidate")
            b_eval = evaluate_budgets(b_macho, args.budget_bytes, args.all_witness_budget_bytes)
            b_schema_bytes = b_macho["schema"]["combinedWitnessAndHelperBytes"]
            b_all_bytes = b_macho["allLiveText"]["combinedWitnessAndHelperBytes"]
            status["baseline"] = {
                "buildRoot": str(b_root),
                "reusedBuildRoot": True,
                "executablePath": str(b_exe),
                "verification": b_verify,
                "machO": b_macho,
                "budgetEvaluation": b_eval,
                "rejectedAsControl": not b_eval["passed"],
            }
            status["sizeComparison"] = {
                "baselineSchemaCombinedWitnessBytes": b_schema_bytes,
                "candidateSchemaCombinedWitnessBytes": c_schema_bytes,
                "savedSchemaCombinedWitnessBytes": b_schema_bytes - c_schema_bytes,
                "candidateOverBaselineSchemaWitnessRatio": c_schema_bytes / b_schema_bytes,
                "baselineAllLiveWitnessBytes": b_all_bytes,
                "candidateAllLiveWitnessBytes": c_all_bytes,
                "savedAllLiveWitnessBytes": b_all_bytes - c_all_bytes,
                "candidateOverBaselineAllLiveWitnessRatio": c_all_bytes / b_all_bytes,
                "baselineLiveTextBytes": b_macho["liveTextBytes"],
                "candidateLiveTextBytes": c_macho["liveTextBytes"],
                "savedLiveTextBytes": b_macho["liveTextBytes"] - c_macho["liveTextBytes"],
            }
            save()

            if not args.skip_throughput:
                status["throughputComparison"] = run_paired_throughput(
                    evidence,
                    b_exe,
                    c_exe,
                    rounds_count=args.rounds,
                    cycles=args.cycles,
                    warmup=args.warmup,
                    repetitions=args.repetitions,
                    base_seed=args.seed,
                )
                save()

        final_identity = source_identities()
        status["sourceIdentityUnchanged"] = final_identity == initial_identity
        if args.reuse_build_root is None and final_identity != initial_identity:
            raise ValueError("Sources changed during measurement")

        if not c_eval["passed"]:
            status["status"] = "fail"
            status["error"] = "; ".join(c_eval["failures"])
            save()
            print(
                f"FAIL (budget): schema={c_schema_bytes} B (limit {args.budget_bytes} B), "
                f"all-live-witness={c_all_bytes} B (limit {args.all_witness_budget_bytes} B), "
                f"live __text={c_macho['liveTextBytes']} B, file={c_macho['machOFileBytes']} B; evidence: {output}",
                file=sys.stderr,
            )
            return 1

        status["status"] = "pass"
        save()
        print(
            f"PASS: schema={c_schema_bytes} B <= {args.budget_bytes} B, "
            f"all-live-witness={c_all_bytes} B <= {args.all_witness_budget_bytes} B "
            f"(live __text={c_macho['liveTextBytes']} B, file={c_macho['machOFileBytes']} B); evidence: {output}"
        )
        return 0
    except Exception as error:
        status["status"] = "fail"
        status["error"] = str(error)
        save()
        print(f"ERROR: {error}; evidence: {output}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
