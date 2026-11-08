"""Build public package products and run a smoke app on an owned iOS 17 Simulator.

The app writes Documents/result.json with a status, systemVersion, and named
checks. Every expected check must pass. The helper always deletes its own device.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time

from platform_build import macro_plugins, platform_arguments, runtime_targets, target_modules, validate_outputs


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_result(result, expected):
    if result.get("status") != "pass" or not result.get("systemVersion", "").startswith("17."):
        raise ValueError("The app did not report success on iOS 17")
    checks = result.get("checks", [])
    if not isinstance(checks, list) or not checks:
        raise ValueError("The app reported no individual checks")
    names = [check.get("id") for check in checks if isinstance(check, dict)]
    if len(names) != len(checks) or any(not isinstance(name, str) or not name for name in names):
        raise ValueError("Every app check needs a nonempty identifier")
    if len(set(names)) != len(names) or set(names) != set(expected):
        raise ValueError("Expected and observed app checks differ: " + repr(names))
    if any(check.get("status") != "pass" for check in checks):
        raise ValueError("An app check failed, skipped, or has an unknown result")


def cleanup_device(device, run):
    errors = []
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", device):
        return False, ["Simulator creation returned an invalid device identifier"]
    try:
        inventory = json.loads(run("devices-cleanup", ["xcrun", "simctl", "list", "devices", "--json"]))
        owned = [item for items in inventory["devices"].values() for item in items if item["udid"] == device]
        if len(owned) != 1:
            raise ValueError("The owned Simulator could not be identified for cleanup")
        if owned[0]["state"] != "Shutdown":
            run("shutdown", ["xcrun", "simctl", "shutdown", device])
    except Exception as error:
        errors.append(str(error))
    try:
        run("delete", ["xcrun", "simctl", "delete", device])
    except Exception as error:
        errors.append(str(error))
    try:
        after = json.loads(run("devices-after", ["xcrun", "simctl", "list", "devices", "--json"]))
        deleted = not any(item["udid"] == device for items in after["devices"].values() for item in items)
        if not deleted:
            errors.append("The owned Simulator remains after deletion")
    except Exception as error:
        errors.append(str(error))
        deleted = False
    return deleted, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Absent directory for the complete evidence")
    parser.add_argument("--source", type=Path, default=Path("Probes/iOSSmoke/Smoke.swift"))
    parser.add_argument("--expect", nargs="+", required=True, help="Exact individual check identifiers")
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--scratch-path", type=Path, help="SwiftPM build directory; the package is built before using its outputs")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-17-5")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-15")
    parser.add_argument("--timeout", type=int, default=120, help="Maximum seconds for the app result")
    args = parser.parse_args()
    if not args.source.is_file() or args.timeout <= 0 or len(set(args.expect)) != len(args.expect):
        parser.error("An existing app source, a positive timeout, and unique expected checks are required")
    evidence = args.output.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    report = {"status": "running", "commands": [], "expected_checks": args.expect,
              "source": str(args.source.resolve()), "source_sha256": digest(args.source),
              "configuration": args.configuration, "runtime_identifier": args.runtime,
              "cleanup": {"created_device_deleted": False}}
    inputs = [args.source, Path("Package.swift"), Path(__file__), Path(__file__).with_name("platform_build.py")]
    inputs += [path for path in Path("Sources").rglob("*") if path.is_file()]
    if Path("Package.resolved").is_file():
        inputs.append(Path("Package.resolved"))
    report["input_sha256"] = {str(path.resolve()): digest(path) for path in inputs}
    device = None
    failure = None

    def save():
        (evidence / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, command, timeout=600):
        command = list(map(str, command))
        log = evidence / (name + ".log")
        try:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            code, output = result.returncode, result.stdout
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            code, output = 124, output + "\nCommand timed out.\n"
        log.write_text(output)
        report["commands"].append({"name": name, "command": command, "exit": code, "log": str(log)})
        save()
        if code != 0:
            raise RuntimeError(name + " failed (" + str(code) + "); see " + str(log))
        return output.strip()

    try:
        compiler = run("compiler-path", ["xcrun", "--find", "swiftc"])
        report["compiler"] = run("compiler-version", [compiler, "--version"])
        if "Swift version 6.4" not in report["compiler"]:
            raise ValueError("The runtime gate requires the selected Swift 6.4 compiler")
        report["xcode"] = run("xcode-version", ["xcodebuild", "-version"])
        report["sdk_build"] = run("sdk-build", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"])
        manifest = json.loads(run("manifest", ["swift", "package", "dump-package"]))
        floors = [entry["version"] for entry in manifest["platforms"] if entry["platformName"] == "ios"]
        if len(floors) != 1 or tuple(map(int, floors[0].split("."))) not in ((16,), (16, 0), (16, 0, 0)):
            raise ValueError("The iOS deployment floor must remain 16.0")
        public = {target for product in manifest["products"] if "library" in product["type"]
                  for target in product["targets"]}
        targets = runtime_targets(manifest, public)
        report["public_modules"] = sorted(public)
        report["shipping_targets"] = sorted(targets)
        scratch = args.scratch_path.resolve() if args.scratch_path else evidence / "build"
        arguments = platform_arguments("ios", floors[0], scratch)
        triple, sdk = arguments[1], arguments[3]
        report["triple"] = triple
        run("build-package", ["swift", "build", "--build-system", "native", "--configuration",
                              args.configuration, *arguments])
        builds = target_modules(scratch, targets, triple, allowed=targets)
        report["module_targets"] = validate_outputs(builds, triple)
        objects = sorted({path for build in builds.values() for path in build["objects"]})
        report["objects"] = [{"path": path, "sha256": digest(Path(path))} for path in objects]
        source_text = args.source.read_text()
        imported = set(re.findall(r"^import (\w+)$", source_text, re.MULTILINE))
        source = evidence / "Smoke.swift"
        source.write_text("".join("import " + name + "\n" for name in sorted(public - imported)) + source_text)
        report["compiled_source_sha256"] = digest(source)
        app = evidence / "StateMachineSmoke.app"
        app.mkdir()
        executable = app / "StateMachineSmoke"
        command = [compiler, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                   "-default-isolation", "MainActor", "-target", triple, "-sdk", sdk,
                   "-parse-as-library", "-module-name", "StateMachineSmoke",
                   "-O" if args.configuration == "release" else "-Onone"]
        for path in sorted({str(Path(build["moduleOutputPath"]).parent) for build in builds.values()}):
            command += ["-I", path]
        for plugin in macro_plugins(builds):
            command += ["-load-plugin-executable", plugin]
        run("build-app", command + [str(source), *objects, "-Xlinker", "-fatal_warnings",
                                    "-Xlinker", "-map", "-Xlinker", str(evidence / "app-link.map"),
                                    "-o", str(executable)])
        bundle = "es.kylehughes.StateMachineSmoke"
        info = {"CFBundleIdentifier": bundle, "CFBundleExecutable": executable.name,
                "CFBundleName": "StateMachineSmoke", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": "16.0",
                "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        run("sign", ["codesign", "--force", "--sign", "-", app])
        for index, artifact in enumerate([str(executable), *objects]):
            metadata = run("deployment-" + str(index), ["xcrun", "vtool", "-show-build", artifact])
            if (re.findall(r"^\s*platform (\S+)$", metadata, re.MULTILINE) != ["IOSSIMULATOR"]
                    or re.findall(r"^\s*minos (\S+)$", metadata, re.MULTILINE) != ["16.0"]):
                raise ValueError("The app or a shipping object has unexpected deployment metadata: " + artifact)
        run("dependencies", ["otool", "-L", executable])
        report["app_sha256"] = digest(executable)
        runtimes = json.loads(run("runtime-inventory", ["xcrun", "simctl", "list", "runtimes", "--json"]))
        selected = next((item for item in runtimes["runtimes"] if item["identifier"] == args.runtime), None)
        if not selected or not selected.get("isAvailable") or not selected["version"].startswith("17."):
            raise ValueError("The required iOS 17 runtime is unavailable")
        report["selected_runtime"] = selected
        run("devices-before", ["xcrun", "simctl", "list", "devices", "--json"])
        device = run("create", ["xcrun", "simctl", "create", "StateMachine-Smoke", args.device_type, args.runtime])
        if not re.fullmatch(r"[A-Fa-f0-9-]{36}", device):
            raise ValueError("Simulator creation did not return a device identifier")
        report["device"] = device
        run("boot", ["xcrun", "simctl", "boot", device])
        run("boot-status", ["xcrun", "simctl", "bootstatus", device, "-b"], timeout=180)
        run("install", ["xcrun", "simctl", "install", device, app])
        run("launch", ["xcrun", "simctl", "launch", device, bundle])
        container = Path(run("container", ["xcrun", "simctl", "get_app_container", device, bundle, "data"]))
        result_path = container / "Documents" / "result.json"
        deadline = time.monotonic() + args.timeout
        while not result_path.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not result_path.is_file():
            raise RuntimeError("The app did not produce its result before the deadline")
        result = json.loads(result_path.read_text())
        (evidence / "runtime-result.json").write_text(json.dumps(result, indent=2) + "\n")
        report["runtime_result"] = result
        validate_result(result, args.expect)
        if any(not Path(path).is_file() or digest(Path(path)) != value
               for path, value in report["input_sha256"].items()):
            raise ValueError("A build input changed during the runtime check")
    except Exception as error:
        failure = str(error)
    finally:
        if device:
            deleted, errors = cleanup_device(device, run)
            report["cleanup"] = {"created_device_deleted": deleted, "errors": errors}
            if errors:
                failure = (failure + "\n" if failure else "") + "Cleanup: " + "; ".join(errors)
        report["status"] = "fail" if failure else "pass"
        report["failure"] = failure
        report["helper_sha256"] = digest(Path(__file__))
        save()
        print(json.dumps({"status": report["status"], "failure": failure,
                          "evidence": str(evidence / "results.json")}, indent=2))
    return 1 if failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
