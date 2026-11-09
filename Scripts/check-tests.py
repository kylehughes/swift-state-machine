"""Run Swift Testing and require nonempty, complete individual observations."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def observe(selection, report):
    if not selection or len(selection) != len(set(selection)):
        raise ValueError("Missing or duplicate selected tests")
    root = ET.fromstring(report)
    cases = root.findall(".//testcase")
    observed = [case.get("classname", "") + "/" + case.get("name", "") for case in cases]
    if sorted(observed) != sorted(selection):
        raise ValueError("Test execution differs from selected individual tests")
    if any(case.find(kind) is not None for case in cases for kind in ("skipped", "failure", "error")):
        raise ValueError("A selected test was skipped or failed")
    return observed


IMPLEMENTATION_ENVIRONMENT = "STATE_MACHINE_MACRO_IMPLEMENTATION_TESTS"
IMPLEMENTATION_TARGET = "StateMachineMacroImplementationTests"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--sanitize", choices=("thread",))
    parser.add_argument("--enable-code-coverage", action="store_true")
    parser.add_argument("--output", type=Path, help="Fresh directory for selected tests and xUnit observations")
    parser.add_argument(
        "--macro-implementation",
        action="store_true",
        help="Run only the opt-in macro implementation tests, in their own scratch path. "
        "Declaring that target makes SwiftPM compile SwiftSyntax from source.",
    )
    args = parser.parse_args()
    common = ["--build-system", "native", "--configuration", args.configuration]
    selection = []
    if args.macro_implementation:
        # The opt-in target changes the package graph; a separate scratch path keeps the default
        # graph's prebuilt-backed products from being rebuilt.
        os.environ[IMPLEMENTATION_ENVIRONMENT] = "1"
        args.scratch_path = args.scratch_path or Path(".build/macro-implementation")
        selection = ["--filter", "^" + IMPLEMENTATION_TARGET + r"\."]
    if args.scratch_path:
        common += ["--scratch-path", str(args.scratch_path.resolve())]
    if args.sanitize:
        common += ["--sanitize", args.sanitize]
    if args.enable_code_coverage:
        common += ["--enable-code-coverage"]
    if args.output:
        args.output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True, timeout=120))
    targets = [target["name"] for target in manifest["targets"] if target["type"] == "test"]
    if args.macro_implementation:
        targets = [name for name in targets if name == IMPLEMENTATION_TARGET]
    selected = subprocess.check_output(["swift", "test", *common, "list", *selection], text=True, timeout=600).splitlines()
    selected = [line.strip() for line in selected if line.strip()]
    if args.macro_implementation:
        # `swift test list` ignores --filter, so narrow the expected selection the same way.
        selected = [line for line in selected if line.startswith(IMPLEMENTATION_TARGET + ".")]
    selected = [line if "/" in line else "/".join(line.rsplit(".", 1)) for line in selected]
    if not targets or any(not any(case.startswith(name + ".") or case.startswith(name + "/") for case in selected) for name in targets):
        raise ValueError("A test target has no selected tests")
    if args.output:
        directory = args.output.resolve()
    else:
        scratch = args.scratch_path or Path(".build")
        directory = Path(tempfile.mkdtemp(prefix="test-observations-", dir=scratch))
    report = directory / "results.xml"
    subprocess.run(
        ["swift", "test", *common, *selection, "--xunit-output", str(report.resolve())], check=True, timeout=600
    )
    reports = list(directory.glob("*.xml"))
    if not reports:
        raise ValueError("Test execution produced no xUnit observations")
    combined = ET.Element("testsuites")
    for path in reports:
        document = ET.fromstring(path.read_bytes())
        for suite in document.findall(".//testsuite"):
            combined.append(suite)
    observed = observe(selected, ET.tostring(combined))
    record = {"expected": selected, "observed": observed, "swift_test_arguments": common + selection}
    if args.enable_code_coverage:
        record["coverage_export"] = subprocess.check_output(
            ["swift", "test", *common, "--show-codecov-path"], text=True, timeout=120
        ).strip()
    (directory / "selection.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Passed {len(observed)} selected tests; observations: {directory}")


if __name__ == "__main__":
    main()
