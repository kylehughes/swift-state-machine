#!/usr/bin/env python3
"""Run the schedule explorer's standard or exhaustive tier across up to four read-only Debug workers.

Builds or updates one SwiftPM native Debug test binary in `--scratch-path`, asks that compiled
binary for its exact `ExplorerTests/full` plan (`EXPLORER_LIST_CONFIGS=1`), runs one config per
read-only `swiftpm-testing-helper` worker (`EXPLORER_CONFIG_INDEX=N`) ordered by costly cases
first, preserves per-unit logs, coverage, L1 windows, and failure artifacts, and writes an
aggregate `receipt.json` bound to the candidate commit, binary SHA-256, and toolchain.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parents[1]
MAX_WORKERS = 4
DEFAULT_SCRATCH_PATH = Path("/tmp/state-machine-explorer")
DEFAULT_UNIT_TIMEOUT_SECONDS = 10800
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}

# Queue-ordering hints for the heaviest configurations (LPT priority only; never assertions).
COST_ORDERING_HINTS: dict[tuple[str, str], float] = {
    ("RuntimeSharedHost", "reconcile"): 3800.0,
    ("MultiOwner.SnapshotObservableObject", "core"): 2000.0,
    ("MultiOwner.SnapshotPresentation", "core"): 1900.0,
    ("OwnerForms.SnapshotObservableObject", "core"): 1825.0,
    ("StateMachineObservableObject", "core+reentrant+resume+chains"): 1335.0,
    ("OwnerForms.SnapshotPresentation", "core"): 1270.0,
    ("StateMachinePresentation", "core+reentrant+resume+chains"): 1050.0,
    ("DistinctSnapshotSequence", "core"): 545.0,
    ("GeneratedOwner.StateMachineObservableObject", "core"): 470.0,
    ("StateMachineObservableObject", "core+resume"): 385.0,
    ("StateMachinePresentation", "core+resume"): 340.0,
    ("GeneratedOwner.StateMachinePresentation", "core"): 338.0,
    ("StateMachineObservableObject", "core+combine+reentrant"): 193.0,
    ("StateMachineObservableObject", "core+combine"): 122.0,
    ("SnapshotObservableObject", "core+second+async+reentrant+pairs+followers"): 119.0,
    ("SnapshotObservableObject", "matrix"): 114.0,
    ("SnapshotPresentation", "core+second+async+reentrant+pairs+followers"): 93.0,
    ("SnapshotPresentation", "matrix"): 86.0,
}

PLAN_COUNT_RE = re.compile(r"^EXPLORER PLAN count=(\d+)$")
PLAN_ITEM_RE = re.compile(r"^EXPLORER PLAN (\d+) (\S+) \[([^\]]+)\] depth (\d+)( hashed)?$")
ROW_RE = re.compile(
    r"^EXPLORER (\S+) \[([^\]]+)\] depth (\d+)( hashed)?: (\d+) sequences run, (\d+) pruned \([^)]*\), deepest (\d+), ([0-9.]+) s$"
)
L1_RE = re.compile(r"^EXPLORER capacity-conflict report windows reached: (\d+)$")
VIOLATION_SUMMARY_RE = re.compile(r"^EXPLORER - `[^`]+` ")
TEST_PASSED_RE = re.compile(r"Test full\(\) passed after [0-9.]+ seconds\.")
RUN_PASSED_RE = re.compile(r"Test run with 1 test in 1 suite passed after [0-9.]+ seconds\.")
DEPRECATION_WARNING_RE = re.compile(r"warning: '--build-system native' has been deprecated[^\n]*\n?")


class ExplorerCheckError(RuntimeError):
    """Fail-closed configuration or verification error."""


@dataclass(frozen=True)
class PlannedUnit:
    index: int
    kind: str
    family: str
    depth: int
    weight: float

    @property
    def key(self) -> str:
        return f"{self.kind} [{self.family}] depth {self.depth}"

    @property
    def unit_id(self) -> str:
        return f"{self.index:03d}__{self.kind}__{self.family}__d{self.depth}"

    @property
    def is_matrix(self) -> bool:
        return self.family == "matrix"

    @property
    def expects_l1_windows(self) -> bool:
        return self.kind == "RuntimeSharedHost" and self.family == "reconcile"


def sha256_file(path: Path) -> str:
    if not path.is_file():
        raise ExplorerCheckError(f"Expected file for SHA-256 digest does not exist: {path}")
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def reject_inherited_explorer_env(environ: Mapping[str, str]) -> None:
    inherited = sorted(key for key in environ if key.startswith("EXPLORER_"))
    if inherited:
        raise ExplorerCheckError("Refusing to run with inherited EXPLORER_* variable(s): " + ", ".join(inherited))


def tier_env_override(tier: str) -> dict[str, str]:
    if tier == "standard":
        return {"EXPLORER_TIER": "standard"}
    if tier == "exhaustive":
        return {"EXPLORER_FULL": "1"}
    raise ExplorerCheckError(f"Unsupported tier: {tier!r}")


def clean_base_env(toolchain: Mapping[str, Any]) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("EXPLORER_") and k != "DYLD_INSERT_LIBRARIES"}
    env.update(
        NSUnbufferedIO="YES",
        DYLD_FRAMEWORK_PATH=toolchain["dyld_framework_path"],
        DYLD_LIBRARY_PATH=toolchain["dyld_library_path"],
    )
    return env


def run_process_to_log(cmd: list[str], env: Mapping[str, str], log_path: Path, timeout: int) -> tuple[int, bool, float]:
    t0 = time.perf_counter()
    timed_out = False
    with log_path.open("w", encoding="utf-8") as handle:
        proc = subprocess.Popen(cmd, cwd=ROOT, env=dict(env), stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            rc = proc.wait()
    return rc, timed_out, time.perf_counter() - t0


def collect_git_info() -> dict[str, Any]:
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=30).strip()
        porcelain = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ExplorerCheckError(f"Failed to query git candidate state: {exc}") from exc
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ExplorerCheckError(f"Unexpected git HEAD commit hash: {head!r}")
    dirty = [line for line in porcelain.splitlines() if line.strip()]
    return {"head_commit": head, "working_tree_clean": not dirty, "dirty_files": dirty}


def resolve_toolchain() -> dict[str, Any]:
    try:
        swift_ver = subprocess.check_output(["swift", "--version"], cwd=ROOT, text=True, stderr=subprocess.STDOUT, timeout=30).strip()
        dev_dir_raw = subprocess.check_output(["xcode-select", "-p"], cwd=ROOT, text=True, timeout=30).strip()
        xcode_ver = subprocess.check_output(["xcodebuild", "-version"], cwd=ROOT, text=True, timeout=30).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        raise ExplorerCheckError(f"Failed to resolve Swift/Xcode toolchain: {exc}") from exc
    if not swift_ver or not dev_dir_raw or not xcode_ver:
        raise ExplorerCheckError("Toolchain diagnostics were empty")
    dev_dir = Path(dev_dir_raw)
    helper = dev_dir / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    frameworks = dev_dir / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    libs = dev_dir / "Platforms/MacOSX.platform/Developer/usr/lib"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ExplorerCheckError(f"swiftpm-testing-helper is unavailable or not executable: {helper}")
    if not frameworks.is_dir() or not libs.is_dir():
        raise ExplorerCheckError(f"MacOSX platform runtime directories missing under {dev_dir}")
    return {
        "swift_version": swift_ver,
        "xcode_version": xcode_ver,
        "developer_dir": str(dev_dir),
        "testing_helper": str(helper),
        "testing_helper_sha256": sha256_file(helper),
        "dyld_framework_path": str(frameworks),
        "dyld_library_path": str(libs),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }


def build_debug_tests(scratch_path: Path, build_log: Path) -> float:
    cmd = ["swift", "build", "--build-system", "native", "--configuration", "debug", "--build-tests", "--scratch-path", str(scratch_path)]
    env = {k: v for k, v in os.environ.items() if not k.startswith("EXPLORER_") and k != "DYLD_INSERT_LIBRARIES"}
    rc, timed_out, elapsed = run_process_to_log(cmd, env, build_log, timeout=1800)
    if timed_out or rc != 0:
        raise ExplorerCheckError(f"Native Debug test build failed (exit {rc}, timed_out={timed_out}). See {build_log}")
    if "Build complete!" not in build_log.read_text(encoding="utf-8", errors="replace"):
        raise ExplorerCheckError(f"Native Debug test build did not report 'Build complete!'. See {build_log}")
    return elapsed


def locate_debug_test_binary(scratch_path: Path) -> Path:
    direct = scratch_path / "debug/StateMachinePackageTests.xctest/Contents/MacOS/StateMachinePackageTests"
    candidates = [direct] if direct.exists() else sorted(
        scratch_path.glob("*/debug/StateMachinePackageTests.xctest/Contents/MacOS/StateMachinePackageTests")
    )
    if len(candidates) != 1:
        raise ExplorerCheckError(f"Expected 1 native Debug StateMachinePackageTests binary under {scratch_path}, found {len(candidates)}")
    binary = candidates[0]
    resolved = binary.resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ExplorerCheckError(f"Debug test binary is missing or not executable: {resolved}")
    if len(resolved.parents) < 4 or resolved.parents[3].name != "debug" or "release" in resolved.parts:
        raise ExplorerCheckError(f"Refusing non-Debug test binary path: {resolved}")
    with resolved.open("rb") as handle:
        if handle.read(4) not in MACHO_MAGICS:
            raise ExplorerCheckError(f"Test binary is not a valid Mach-O executable: {resolved}")
    return binary


def parse_compiled_plan(returncode: int, timed_out: bool, log_text: str) -> list[PlannedUnit]:
    if timed_out or returncode != 0:
        raise ExplorerCheckError(f"Compiled explorer plan query failed (rc={returncode}, timed_out={timed_out})")
    cleaned = DEPRECATION_WARNING_RE.sub("", log_text)
    if (
        "Test run with 0 tests" in cleaned
        or "recorded an issue" in cleaned
        or "Test full() failed" in cleaned
        or not TEST_PASSED_RE.search(cleaned)
        or not RUN_PASSED_RE.search(cleaned)
    ):
        raise ExplorerCheckError("Compiled explorer plan query did not pass cleanly with 1 test in 1 suite")

    declared_count: int | None = None
    items: list[PlannedUnit] = []
    for raw_line in cleaned.splitlines():
        line = raw_line.rstrip("\r")
        if not line.startswith("EXPLORER "):
            continue
        if m_count := PLAN_COUNT_RE.match(line):
            if declared_count is not None:
                raise ExplorerCheckError("Duplicate EXPLORER PLAN count header")
            declared_count = int(m_count.group(1))
        elif m_item := PLAN_ITEM_RE.match(line):
            idx_s, kind, family, depth_s, hashed = m_item.groups()
            if hashed:
                raise ExplorerCheckError(f"Plan contains state-hashed configuration: {line}")
            depth = int(depth_s)
            if depth <= 0:
                raise ExplorerCheckError(f"Plan contains non-positive depth: {line}")
            items.append(PlannedUnit(int(idx_s), kind, family, depth, COST_ORDERING_HINTS.get((kind, family), 10.0)))
        else:
            raise ExplorerCheckError(f"Unrecognized EXPLORER line during plan query: {line}")

    if declared_count is None or declared_count <= 0:
        raise ExplorerCheckError(f"Missing or empty EXPLORER PLAN count header (got {declared_count!r})")
    if len(items) != declared_count or [u.index for u in items] != list(range(declared_count)):
        raise ExplorerCheckError(f"EXPLORER PLAN count/index mismatch (declared={declared_count}, parsed={len(items)})")
    if len({u.key for u in items}) != len(items):
        raise ExplorerCheckError("EXPLORER PLAN contains duplicate configuration keys")
    return items


def query_compiled_plan(tier: str, binary: Path, toolchain: Mapping[str, Any], output_dir: Path) -> list[PlannedUnit]:
    plan_log = output_dir / "plan.log"
    env = dict(clean_base_env(toolchain), EXPLORER_SMOKE="0", EXPLORER_LIST_CONFIGS="1", **tier_env_override(tier))
    cmd = [toolchain["testing_helper"], "--test-bundle-path", str(binary), "--testing-library", "swift-testing", "--filter", "ExplorerTests/full"]
    rc, timed_out, _ = run_process_to_log(cmd, env, plan_log, timeout=120)
    units = parse_compiled_plan(rc, timed_out, plan_log.read_text(encoding="utf-8", errors="replace") if plan_log.is_file() else "")
    (output_dir / "plan.json").write_text(
        json.dumps([{"index": u.index, "kind": u.kind, "family": u.family, "depth": u.depth, "key": u.key} for u in units], indent=2) + "\n",
        encoding="utf-8",
    )
    return units


def verify_unit_output(
    unit: PlannedUnit, tier: str, returncode: int, timed_out: bool, log_text: str, fail_path: Path, all_path: Path, cov_path: Path
) -> dict[str, Any]:
    errors: list[str] = []
    if timed_out:
        errors.append("unit timed out")
    if returncode != 0:
        errors.append(f"non-zero exit code {returncode}")
    if not log_text.strip():
        errors.append("empty unit log")

    cleaned = DEPRECATION_WARNING_RE.sub("", log_text)
    if "Test run with 0 tests" in cleaned:
        errors.append("no tests ran ('Test run with 0 tests')")
    if not TEST_PASSED_RE.search(cleaned):
        errors.append("missing 'Test full() passed after ... seconds.'")
    if not RUN_PASSED_RE.search(cleaned):
        errors.append("missing 'Test run with 1 test in 1 suite passed after ... seconds.'")
    for token in ("  VIOLATION ", "recorded an issue", "Test full() failed"):
        if token in cleaned:
            errors.append(f"log contains {token!r}")

    fault_files = [str(p) for p in (fail_path, all_path) if p.exists() and p.stat().st_size > 0]
    if fault_files:
        errors.append(f"non-empty failure file(s): {', '.join(fault_files)}")

    rows: list[dict[str, Any]] = []
    l1_matches: list[int] = []
    unrecognized: list[str] = []
    for raw_line in cleaned.splitlines():
        line = raw_line.rstrip("\r")
        if not line.startswith("EXPLORER "):
            continue
        if m_row := ROW_RE.match(line):
            kind, family, depth_s, hashed, seq_s, pruned_s, deepest_s, sec_s = m_row.groups()
            depth, seqs, pruned, deepest, secs = int(depth_s), int(seq_s), int(pruned_s), int(deepest_s), float(sec_s)
            key = f"{kind} [{family}] depth {depth}"
            rows.append({"kind": kind, "family": family, "depth": depth, "hashed": bool(hashed), "sequences": seqs, "pruned": pruned, "deepest": deepest, "seconds": secs, "key": key})
            if hashed:
                errors.append(f"state hashing enabled on {key}")
            if seqs <= 0:
                errors.append(f"zero sequences executed for {key}")
            if deepest < 1 or deepest > depth:
                errors.append(f"unexpected deepest={deepest} for {key}")
        elif m_l1 := L1_RE.match(line):
            l1_matches.append(int(m_l1.group(1)))
        elif VIOLATION_SUMMARY_RE.match(line):
            errors.append(f"violation summary emitted: {line}")
        else:
            unrecognized.append(line)

    if unrecognized:
        errors.append(f"unrecognized EXPLORER line(s): {unrecognized[:3]}")
    if not rows:
        errors.append("no EXPLORER configuration summary row found")

    depth_mismatches = sorted({
        f"{r['kind']} [{r['family']}]: observed depth {r['depth']}, expected depth {unit.depth} for tier {tier}"
        for r in rows if r["kind"] == unit.kind and r["family"] == unit.family and r["depth"] != unit.depth
    })
    if depth_mismatches:
        errors.append("mislabeled depth/tier: " + "; ".join(depth_mismatches))

    observed_keys = [r["key"] for r in rows]
    if observed_keys != [unit.key]:
        if observed_keys.count(unit.key) > 1:
            errors.append(f"duplicate config(s): {[unit.key]}")
        if unit.key not in observed_keys:
            errors.append(f"missing expected config: {unit.key}")
        extras = [k for k in observed_keys if k != unit.key]
        if extras:
            errors.append(f"unexpected extra config(s): {extras}")

    l1_total = sum(l1_matches)
    if unit.expects_l1_windows and (not l1_matches or l1_total <= 0):
        errors.append("missing or zero EXPLORER capacity-conflict report windows reached diagnostic")

    coverage_lines: list[str] = []
    if not cov_path.is_file():
        errors.append(f"missing EXPLORER_COVERAGE output file: {cov_path}")
    else:
        malformed, wrong_kind = [], []
        for line in cov_path.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            fields = stripped.split("|")
            if len(fields) != 8 or any(not f for f in fields):
                malformed.append(stripped)
            else:
                if fields[0] != unit.kind:
                    wrong_kind.append(stripped)
                coverage_lines.append(stripped)
        if malformed:
            errors.append(f"malformed EXPLORER_COVERAGE cell(s): {malformed[:3]}")
        if wrong_kind:
            errors.append(f"coverage cell(s) recorded unexpected class for {unit.kind}: {wrong_kind[:3]}")
        if unit.is_matrix and not coverage_lines:
            errors.append(f"matrix unit {unit.unit_id} recorded 0 coverage cells")

    unique_cov = sorted(set(coverage_lines))
    return {
        "passed": not errors,
        "errors": errors,
        "rows": rows,
        "l1_windows": l1_total,
        "coverage_lines": unique_cov,
        "coverage_count": len(unique_cov),
        "fault_files": fault_files,
        "depth_mismatches": depth_mismatches,
    }


def run_one_unit(
    unit: PlannedUnit, tier: str, binary: Path, toolchain: Mapping[str, Any], base_env: Mapping[str, str], output_dir: Path, worker_id: int, unit_timeout: int
) -> dict[str, Any]:
    log_path = output_dir / "units" / f"{unit.unit_id}.log"
    receipt_path = output_dir / "units" / f"{unit.unit_id}.json"
    fail_path = output_dir / "failures" / f"{unit.unit_id}.failures"
    all_path = output_dir / "failures" / f"{unit.unit_id}.all"
    cov_path = output_dir / "coverage" / f"{unit.unit_id}.txt"

    overrides = {
        "EXPLORER_SMOKE": "0",
        "EXPLORER_CONFIG_INDEX": str(unit.index),
        "EXPLORER_FAILURES": str(fail_path),
        "EXPLORER_ALL": str(all_path),
        "EXPLORER_COVERAGE": str(cov_path),
        **tier_env_override(tier),
    }
    cmd = [toolchain["testing_helper"], "--test-bundle-path", str(binary), "--testing-library", "swift-testing", "--filter", "ExplorerTests/full"]
    t0 = time.perf_counter()
    rc, timed_out, wall = run_process_to_log(cmd, dict(base_env, **overrides), log_path, timeout=unit_timeout)
    t1 = t0 + wall

    log_text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
    verified = verify_unit_output(unit, tier, rc, timed_out, log_text, fail_path, all_path, cov_path)
    record = {
        "unit_id": unit.unit_id, "index": unit.index, "kind": unit.kind, "family": unit.family, "depth": unit.depth,
        "expected_key": unit.key, "queue_weight": unit.weight, "worker": worker_id,
        "start_monotonic": t0, "end_monotonic": t1, "wall_seconds": round(wall, 4),
        "returncode": rc, "timed_out": timed_out, "command": cmd, "environment_overrides": overrides,
        "log_path": str(log_path), "coverage_path": str(cov_path), "failures_path": str(fail_path), "all_findings_path": str(all_path),
        "passed": verified["passed"], "errors": verified["errors"], "rows": verified["rows"],
        "l1_windows": verified["l1_windows"], "coverage_count": verified["coverage_count"],
        "fault_files": verified["fault_files"], "depth_mismatches": verified["depth_mismatches"],
    }
    receipt_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return {**record, "_coverage_lines": verified["coverage_lines"]}


def execute_units(
    units: list[PlannedUnit], tier: str, binary: Path, toolchain: Mapping[str, Any], output_dir: Path, workers: int, unit_timeout: int
) -> tuple[list[dict[str, Any]], float]:
    base_env = clean_base_env(toolchain)
    queue = sorted(units, key=lambda u: (-u.weight, u.index))
    lock, next_idx, done_count, results = threading.Lock(), [0], [0], []

    def worker_loop(wid: int) -> list[dict[str, Any]]:
        local: list[dict[str, Any]] = []
        while True:
            with lock:
                i = next_idx[0]
                if i >= len(queue):
                    break
                next_idx[0] += 1
                unit = queue[i]
            res = run_one_unit(unit, tier, binary, toolchain, base_env, output_dir, wid, unit_timeout)
            local.append(res)
            with lock:
                done_count[0] += 1
                seqs = sum(r["sequences"] for r in res["rows"])
                print(f"[{done_count[0]}/{len(queue)}] worker={wid} unit={res['unit_id']} passed={res['passed']} seqs={seqs:,} wall={res['wall_seconds']:.1f}s", flush=True)
        return local

    t0 = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for fut in concurrent.futures.as_completed([ex.submit(worker_loop, w) for w in range(workers)]):
            results.extend(fut.result())
    return results, time.perf_counter() - t0


def aggregate_and_verify(
    tier: str, workers: int, scratch_path: Path, output_dir: Path, binary: Path, binary_sha_before: str, binary_sha_after: str,
    git_before: Mapping[str, Any], head_after: str, toolchain: Mapping[str, Any], planned_units: list[PlannedUnit],
    unit_results: list[dict[str, Any]], build_seconds: float, exec_wall_seconds: float, started_utc: str, finished_utc: str,
) -> dict[str, Any]:
    errors: list[str] = []
    if binary_sha_before != binary_sha_after:
        errors.append(f"Test binary SHA-256 changed: before={binary_sha_before}, after={binary_sha_after}")
    if git_before["head_commit"] != head_after:
        errors.append(f"Git HEAD changed: before={git_before['head_commit']}, after={head_after}")

    planned_ids, completed_ids = [u.unit_id for u in planned_units], [r["unit_id"] for r in unit_results]
    if collections.Counter(completed_ids) != collections.Counter(planned_ids):
        errors.append(f"Completed unit mismatch: missing={sorted(set(planned_ids) - set(completed_ids))}, extra={sorted(set(completed_ids) - set(planned_ids))}")

    failed_units = sorted(r["unit_id"] for r in unit_results if not r["passed"])
    for res in sorted(unit_results, key=lambda r: r["index"]):
        if not res["passed"]:
            errors.append(f"unit {res['unit_id']} failed: {'; '.join(res['errors'])}")

    all_rows = [row for res in unit_results for row in res["rows"]]
    expected_counter, observed_counter = collections.Counter(u.key for u in planned_units), collections.Counter(r["key"] for r in all_rows)
    missing_configs = sorted((expected_counter - observed_counter).elements())
    extra_configs = sorted((observed_counter - expected_counter).elements())
    duplicate_configs = sorted(k for k, c in observed_counter.items() if c > 1)
    expected_depth = {(u.kind, u.family): u.depth for u in planned_units}
    depth_mismatches = sorted({
        f"{r['kind']} [{r['family']}]: observed depth {r['depth']}, expected depth {expected_depth[(r['kind'], r['family'])]} for tier {tier}"
        for r in all_rows if (r["kind"], r["family"]) in expected_depth and expected_depth[(r["kind"], r["family"])] != r["depth"]
    })
    for label, items in (("missing expected config(s)", missing_configs), ("duplicate config(s)", duplicate_configs), ("unexpected extra config(s)", extra_configs), ("mislabeled depth/tier", depth_mismatches)):
        if items:
            errors.append(f"{label}: {items[:5]}")

    l1_by_unit = {r["unit_id"]: r["l1_windows"] for r in sorted(unit_results, key=lambda x: x["index"]) if r["l1_windows"] > 0}
    l1_total = sum(r["l1_windows"] for r in unit_results)
    if any(u.expects_l1_windows for u in planned_units) and l1_total <= 0:
        errors.append("aggregate L1 capacity-conflict report windows reached is 0")
    l1_path = output_dir / "l1-windows.json"
    l1_path.write_text(json.dumps({"tier": tier, "total_windows": l1_total, "by_unit": l1_by_unit}, indent=2) + "\n", encoding="utf-8")

    unit_by_id = {u.unit_id: u for u in planned_units}
    all_cov = sorted({c for r in unit_results for c in r.get("_coverage_lines", [])})
    matrix_cov = sorted({c for r in unit_results if unit_by_id.get(r["unit_id"]) and unit_by_id[r["unit_id"]].is_matrix for c in r.get("_coverage_lines", [])})
    if any(u.is_matrix for u in planned_units) and not matrix_cov:
        errors.append("aggregate matrix coverage cells count is 0")
    cov_path = output_dir / "coverage-cells.txt"
    cov_path.write_text("".join(line + "\n" for line in all_cov), encoding="utf-8")

    failure_files = sorted(r["failures_path"] for r in unit_results if Path(r["failures_path"]).is_file() and Path(r["failures_path"]).stat().st_size > 0)
    all_finding_files = sorted(r["all_findings_path"] for r in unit_results if Path(r["all_findings_path"]).is_file() and Path(r["all_findings_path"]).stat().st_size > 0)
    agg_failures, agg_all = None, None
    if failure_files:
        p = output_dir / "failures.md"
        p.write_text("".join(Path(f).read_text(encoding="utf-8", errors="replace") for f in failure_files), encoding="utf-8")
        agg_failures = str(p)
    if all_finding_files:
        p = output_dir / "all-findings.txt"
        p.write_text("".join(Path(f).read_text(encoding="utf-8", errors="replace") for f in all_finding_files), encoding="utf-8")
        agg_all = str(p)

    worker_busy: dict[int, float] = collections.defaultdict(float)
    worker_spans: dict[int, float] = {}
    idle_tail = 0.0
    if unit_results:
        t_min = min(r["start_monotonic"] for r in unit_results)
        worker_end: dict[int, float] = {}
        for r in unit_results:
            worker_busy[r["worker"]] += r["wall_seconds"]
            worker_end[r["worker"]] = max(worker_end.get(r["worker"], r["start_monotonic"]), r["end_monotonic"])
        worker_spans = {w: round(worker_end[w] - t_min, 2) for w in sorted(worker_end)}
        idle_tail = round(max(worker_spans.values()) - min(worker_spans.values()), 2) if worker_spans else 0.0

    sum_unit_wall = sum(r["wall_seconds"] for r in unit_results)
    receipt = {
        "schema_version": 2,
        "passed": not errors,
        "errors": errors,
        "tier": tier,
        "workers": workers,
        "candidate": {"head_commit": git_before["head_commit"], "head_commit_after": head_after, "working_tree_clean": git_before["working_tree_clean"], "dirty_files": git_before["dirty_files"]},
        "binary": {"path": str(binary), "resolved_path": str(binary.resolve()), "scratch_path": str(scratch_path), "configuration": "debug", "sha256_before": binary_sha_before, "sha256_after": binary_sha_after, "sha256_unchanged": binary_sha_before == binary_sha_after},
        "toolchain": {k: toolchain[k] for k in ("swift_version", "xcode_version", "developer_dir", "testing_helper", "testing_helper_sha256", "platform", "machine")},
        "timing": {
            "started_utc": started_utc, "finished_utc": finished_utc, "build_seconds": round(build_seconds, 3),
            "exec_wall_seconds": round(exec_wall_seconds, 3), "total_wall_seconds": round(build_seconds + exec_wall_seconds, 3),
            "sum_unit_wall_seconds": round(sum_unit_wall, 3), "sum_reported_seconds": round(sum(r["seconds"] for r in all_rows), 2),
            "effective_parallelism": round(sum_unit_wall / exec_wall_seconds, 3) if exec_wall_seconds > 0 else 0.0,
            "worker_spans_seconds": {str(w): v for w, v in worker_spans.items()},
            "worker_busy_seconds": {str(w): round(v, 2) for w, v in sorted(worker_busy.items())},
            "idle_tail_seconds": idle_tail,
        },
        "coverage": {
            "all_units_cells_count": len(all_cov),
            "all_units_cells_sha256": hashlib.sha256("\n".join(all_cov).encode("utf-8")).hexdigest() if all_cov else "",
            "matrix_units_cells_count": len(matrix_cov),
            "matrix_units_cells_sha256": hashlib.sha256("\n".join(matrix_cov).encode("utf-8")).hexdigest() if matrix_cov else "",
            "cells_file": str(cov_path),
        },
        "l1_windows": {"total": l1_total, "by_unit": l1_by_unit, "receipt_file": str(l1_path)},
        "configurations": {
            "planned_count": len(planned_units), "observed_count": len(all_rows), "units_completed": len(unit_results),
            "failed_units": failed_units, "missing_configs": missing_configs, "duplicate_configs": duplicate_configs,
            "extra_configs": extra_configs, "depth_or_tier_mismatches": depth_mismatches,
            "sequences_total": sum(r["sequences"] for r in all_rows), "pruned_total": sum(r["pruned"] for r in all_rows),
            "per_config": {r["key"]: {"sequences": r["sequences"], "pruned": r["pruned"], "deepest": r["deepest"], "seconds": r["seconds"]} for r in sorted(all_rows, key=lambda x: x["key"])},
        },
        "failures": {"failure_files": failure_files, "all_finding_files": all_finding_files, "aggregated_failures_file": agg_failures, "aggregated_all_file": agg_all},
        "units": [
            {
                "index": r["index"], "unit_id": r["unit_id"], "expected_key": r["expected_key"], "worker": r["worker"],
                "wall_seconds": r["wall_seconds"], "returncode": r["returncode"], "timed_out": r["timed_out"],
                "passed": r["passed"], "errors": r["errors"], "sequences": sum(row["sequences"] for row in r["rows"]),
                "l1_windows": r["l1_windows"], "coverage_count": r["coverage_count"], "log_path": r["log_path"],
                "receipt_path": str(output_dir / "units" / f"{r['unit_id']}.json"),
            }
            for r in sorted(unit_results, key=lambda item: item["index"])
        ],
    }
    (output_dir / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tier", choices=("standard", "exhaustive"), required=True, help="Explorer tier to verify.")
    parser.add_argument("--output", type=Path, required=True, help="Fresh non-existent output directory.")
    parser.add_argument("--scratch-path", type=Path, default=DEFAULT_SCRATCH_PATH, help=f"SwiftPM Debug scratch path (default: {DEFAULT_SCRATCH_PATH}).")
    parser.add_argument("--workers", type=int, default=MAX_WORKERS, help=f"Concurrent read-only workers, 1..{MAX_WORKERS} (default: {MAX_WORKERS}).")
    parser.add_argument("--unit-timeout", type=int, default=DEFAULT_UNIT_TIMEOUT_SECONDS, help=f"Per-unit timeout in seconds (default: {DEFAULT_UNIT_TIMEOUT_SECONDS}).")
    args = parser.parse_args(argv)

    try:
        if args.workers < 1 or args.workers > MAX_WORKERS:
            raise ExplorerCheckError(f"--workers must be between 1 and {MAX_WORKERS}, got {args.workers}")
        if args.unit_timeout <= 0:
            raise ExplorerCheckError(f"--unit-timeout must be positive, got {args.unit_timeout}")
        reject_inherited_explorer_env(os.environ)

        output_dir, scratch_path = args.output.resolve(), args.scratch_path.resolve()
        if output_dir.exists():
            raise ExplorerCheckError(f"--output directory already exists (require fresh path): {output_dir}")
        git_before, toolchain = collect_git_info(), resolve_toolchain()

        output_dir.mkdir(parents=True, exist_ok=False)
        for sub in ("units", "failures", "coverage"):
            (output_dir / sub).mkdir()

        started_utc = datetime.now(timezone.utc).isoformat()
        print(f"Building native Debug test binary in {scratch_path} (tier={args.tier}, workers={args.workers})...", flush=True)
        build_seconds = build_debug_tests(scratch_path, output_dir / "build.log")
        binary = locate_debug_test_binary(scratch_path)
        binary_sha_before = sha256_file(binary)

        planned_units = query_compiled_plan(args.tier, binary, toolchain, output_dir)
        print(
            f"Candidate {git_before['head_commit'][:12]} (clean={git_before['working_tree_clean']}) "
            f"binary={binary} sha256={binary_sha_before[:16]}... planned={len(planned_units)} configs",
            flush=True,
        )

        unit_results, exec_wall = execute_units(planned_units, args.tier, binary, toolchain, output_dir, args.workers, args.unit_timeout)
        receipt = aggregate_and_verify(
            args.tier, args.workers, scratch_path, output_dir, binary, binary_sha_before, sha256_file(binary),
            git_before, collect_git_info()["head_commit"], toolchain, planned_units, unit_results,
            build_seconds, exec_wall, started_utc, datetime.now(timezone.utc).isoformat(),
        )
        cfg, timing, cov, l1 = receipt["configurations"], receipt["timing"], receipt["coverage"], receipt["l1_windows"]
        status = "PASSED" if receipt["passed"] else "FAILED"
        print(
            f"{status}: tier={args.tier} workers={args.workers} configs={cfg['observed_count']}/{cfg['planned_count']} "
            f"seqs={cfg['sequences_total']:,} l1={l1['total']} cov_cells={cov['all_units_cells_count']} "
            f"wall={timing['total_wall_seconds']:.1f}s (build={timing['build_seconds']:.1f}s, exec={timing['exec_wall_seconds']:.1f}s, "
            f"eff_par={timing['effective_parallelism']:.2f}x, idle_tail={timing['idle_tail_seconds']:.1f}s) receipt={output_dir / 'receipt.json'}",
            flush=True,
        )
        if not receipt["passed"]:
            for err in receipt["errors"]:
                print(f"ERROR: {err}", file=sys.stderr, flush=True)
            return 1
        return 0
    except ExplorerCheckError as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
