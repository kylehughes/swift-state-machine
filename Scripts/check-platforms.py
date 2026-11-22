"""Build and link a public-call consumer at declared Apple platform floors.

The optional distribution lane imports package text interfaces without package
binary modules. Neither lane executes the linked library on an OS runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from platform_build import DEVICE_PLATFORMS, PLATFORMS, macro_plugins, platform_arguments, rebuild_visionos, runtime_targets, target_modules, validate_outputs

def shipping_targets(manifest):
    """Select library roots and their package runtime dependencies, never tests/macros."""
    public = {target for product in manifest["products"] if "library" in product["type"]
              for target in product["targets"]}
    return public, runtime_targets(manifest, public)


def run_observed(command, log, input_text=None):
    try:
        with log.open("w") as output:
            result = subprocess.run(command, input=input_text, text=True, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        return {"command": command, "exit": result.returncode, "log": str(log)}
    except subprocess.TimeoutExpired:
        return {"command": command, "exit": None, "status": "timeout", "log": str(log)}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interfaces", action="store_true",
                        help="Build distribution interfaces and link through text-only package interfaces")
    parser.add_argument("--device", action="store_true",
                        help="Build mobile device architectures instead of simulators and the Mac host")
    parser.add_argument("--output", type=Path, help="Absent directory for retained logs and build products")
    args = parser.parse_args()
    manifest = json.loads(subprocess.check_output(
        ["swift", "package", "dump-package"], text=True, timeout=120))
    Path(".build").mkdir(exist_ok=True)
    if args.output:
        evidence = args.output.resolve()
        evidence.mkdir(parents=True, exist_ok=False)
    else:
        evidence = Path(tempfile.mkdtemp(prefix="platform-observations-", dir=".build")).resolve()
    public, targets = shipping_targets(manifest)
    platforms = DEVICE_PLATFORMS if args.device else PLATFORMS
    selected = [entry for entry in manifest.get("platforms", []) if entry["platformName"] in platforms]
    if not selected:
        raise ValueError("No declared Apple platforms")
    source_template = Path("Probes/PlatformCheck/Consumer.swift")
    source_text = source_template.read_text()
    imported = set(re.findall(r"^import (\w+)$", source_text, re.MULTILINE))
    if not {"StateMachine", "StateMachineUI"} <= public:
        raise ValueError("The public-call consumer requires the StateMachine and StateMachineUI products")
    for module in public:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", module):
            raise ValueError("Unsupported Swift module identifier: " + module)
    source = evidence / "Consumer.swift"
    source.write_text("".join("import " + module + "\n" for module in sorted(public - imported)) + source_text)
    observations = []

    def save():
        (evidence / "results.json").write_text(json.dumps(observations, indent=2) + "\n")

    for entry in selected:
        name, floor = entry["platformName"], entry["version"]
        sdk_name = platforms[name][1]
        scratch = evidence / name
        arguments = platform_arguments(name, floor, scratch, device=args.device)
        triple, sdk = arguments[1], arguments[3]
        command = ["swift", "build", "--build-system", "native", "--configuration", "release", *arguments]
        if args.interfaces:
            command += ["--enable-parseable-module-interfaces", "-Xswiftc", "-enable-library-evolution"]
        observation = {"platform": name, "minimum": floor, "triple": triple, "sdk": sdk,
                       "destination": "device" if args.device else "simulator-or-host",
                       "public_modules": sorted(public), "shipping_targets": sorted(targets),
                       "source": str(source), "source_sha256": digest(source), "classifications": {}}
        observations.append(observation)
        build = run_observed(command, evidence / (name + ".log"))
        observation.update({"command": command, "exit": build["exit"], "build": build})
        save()
        if build["exit"] != 0:
            raise RuntimeError("Platform build failed: " + name + ". See " + str(evidence))
        observation["classifications"]["build"] = "build-validated"
        save()
        builds = target_modules(scratch, targets, triple, allow_visionos_plan=name == "visionos", allowed=targets)
        rebuilt = rebuild_visionos(builds, triple, sdk_name, evidence, run_observed) if name == "visionos" else []
        observation["canonical_target_rebuild"] = rebuilt
        if rebuilt:
            observation["classifications"]["build"] = "canonical-visionos-compiled-from-native-plan"
        observation["module_targets"] = validate_outputs(builds, triple)
        save()
        objects = sorted({path for build in builds.values() for path in build["objects"]})
        observation["objects"] = [{"path": path, "sha256": digest(Path(path))} for path in objects]
        if args.interfaces:
            imports = evidence / (name + "-public-interfaces")
            imports.mkdir()
            interfaces = {}
            for module, build in sorted(builds.items()):
                interface = Path(build["moduleOutputPath"]).with_suffix(".swiftinterface")
                if not interface.is_file() or "-target " + triple not in interface.read_text():
                    raise ValueError("Missing target-matching public interface for " + module)
                shutil.copyfile(interface, imports / interface.name)
                interfaces[module] = [str(interface)]
            observation["interfaces"] = interfaces
            import_paths = [str(imports)]
        else:
            import_paths = sorted({str(Path(build["moduleOutputPath"]).parent) for build in builds.values()})
        common = ["xcrun", "--sdk", sdk_name, "swiftc", "-swift-version", "6", "-warnings-as-errors", "-target", triple,
                  "-sdk", sdk, "-module-name", "StateMachinePlatformCheck", "-module-cache-path",
                  str(evidence / (name + "-consumer-cache"))]
        for path in import_paths:
            common += ["-I", path]
        for plugin in macro_plugins(builds):
            common += ["-load-plugin-executable", plugin]
        if args.interfaces:
            consumer = run_observed(common + ["-typecheck", str(source)], evidence / (name + "-interface-import.log"))
            observation.update({"interface_import_command": consumer["command"], "interface_import_exit": consumer["exit"],
                                "interface_import": consumer})
            save()
            if consumer["exit"] != 0:
                raise RuntimeError("Interface-only public-call compilation failed: " + name + ". See " + str(evidence))
            observation["classifications"]["interface"] = "text-interface-public-call-validated"
        library = evidence / (name + "-PlatformCheck.dylib")
        link = run_observed(common + ["-emit-library", "-parse-as-library", "-Xlinker", "-fatal_warnings",
                                     "-Xlinker", "-map", "-Xlinker", str(evidence / (name + "-link.map")),
                                     str(source), *objects, "-o", str(library)], evidence / (name + "-link.log"))
        observation["link"] = link
        save()
        if link["exit"] != 0 or not library.is_file():
            raise RuntimeError("Public-call consumer link failed: " + name + ". See " + str(evidence))
        symbols = run_observed(["xcrun", "nm", "-gU", str(library)], evidence / (name + "-symbols.log"))
        observation["symbols"] = symbols
        save()
        if symbols["exit"] != 0:
            raise RuntimeError("Linked public consumer symbols unavailable: " + name)
        demangled = run_observed(["xcrun", "swift-demangle"], evidence / (name + "-demangled-symbols.log"),
                                 Path(symbols["log"]).read_text())
        observation["demangled_symbols"] = demangled
        save()
        if (demangled["exit"] != 0
                or "StateMachinePlatformCheck.stateMachinePlatformCheck()" not in Path(demangled["log"]).read_text()):
            raise RuntimeError("Linked public consumer export missing: " + name)
        undefined = run_observed(["xcrun", "nm", "-u", str(library)],
                                 evidence / (name + "-undefined-symbols.log"))
        dependencies = run_observed(["otool", "-L", str(library)],
                                    evidence / (name + "-dependencies.log"))
        observation.update({"undefined_symbols": undefined, "dependencies": dependencies})
        save()
        if undefined["exit"] != 0 or dependencies["exit"] != 0:
            raise RuntimeError("Linked consumer dependency inspection failed: " + name)
        expected_platform = ({"ios": "IOS", "tvos": "TVOS", "watchos": "WATCHOS", "visionos": "VISIONOS"}
                             if args.device else
                             {"ios": "IOSSIMULATOR", "macos": "MACOS", "tvos": "TVOSSIMULATOR",
                              "watchos": "WATCHOSSIMULATOR", "visionos": "VISIONOSSIMULATOR",
                              "maccatalyst": "MACCATALYST"})[name]
        metadata_results = []
        for index, artifact in enumerate([str(library), *objects]):
            metadata = run_observed(["xcrun", "vtool", "-show-build", artifact],
                                    evidence / (name + "-build-metadata-" + str(index) + ".log"))
            metadata_results.append(metadata)
            observation["build_metadata"] = metadata_results
            save()
            metadata_text = Path(metadata["log"]).read_text()
            metadata_platforms = re.findall(r"^\s*platform (\S+)$", metadata_text, re.MULTILINE)
            minima = re.findall(r"^\s*minos (\S+)$", metadata_text, re.MULTILINE)
            normalize = lambda version: tuple(int(part) for part in version.split(".")) + (0,) * (3 - len(version.split(".")))
            if (metadata["exit"] != 0 or metadata_platforms != [expected_platform] or len(minima) != 1
                    or normalize(minima[0]) != normalize(floor)):
                raise RuntimeError("Linked library/object platform minimum metadata mismatch: " + artifact)
        observation.update({"library": str(library), "library_sha256": digest(library),
                            "evidence": "build-and-link-validated"})
        observation["classifications"]["link"] = "public-call-linked-library-validated"
        save()
        print(name + " " + floor + ": build-and-link-validated (no runtime execution)")
    print("Platform observations: " + str(evidence))


if __name__ == "__main__":
    main()
