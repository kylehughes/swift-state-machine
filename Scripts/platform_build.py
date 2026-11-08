"""Inspect native SwiftPM plans and repair its unsupported visionOS target spelling.

The adapter recompiles shipping Swift modules only. Native SwiftPM continues to
build host macro/plugin tools with their original host settings.
"""
import json
from pathlib import Path
import platform
import subprocess
import re


PLATFORMS = {
    "ios": ("ios", "iphonesimulator", "-simulator"),
    "tvos": ("tvos", "appletvsimulator", "-simulator"),
    "watchos": ("watchos", "watchsimulator", "-simulator"),
    "visionos": ("xros", "xrsimulator", "-simulator"),
    "maccatalyst": ("ios", "macosx", "-macabi"),
    "macos": ("macosx", "macosx", ""),
}

DEVICE_PLATFORMS = {
    "ios": ("ios", "iphoneos", "arm64"),
    "tvos": ("tvos", "appletvos", "arm64"),
    "watchos": ("watchos", "watchos", "arm64_32"),
    "visionos": ("xros", "xros", "arm64"),
}


def platform_arguments(name, floor, scratch, device=False):
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise ValueError("Unsupported host architecture: " + architecture)
    if device:
        operating_system, sdk_name, architecture = DEVICE_PLATFORMS[name]
        suffix = ""
    else:
        operating_system, sdk_name, suffix = PLATFORMS[name]
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True, timeout=60).strip()
    if not sdk or not Path(sdk).is_dir():
        raise ValueError("SDK directory is missing: " + sdk_name)
    return ["--triple", architecture + "-apple-" + operating_system + floor + suffix,
            "--sdk", sdk, "--scratch-path", str(scratch)]


def macro_plugins(commands):
    """Extract driver or frontend-forwarded macro executable arguments from a native plan."""
    plugins = set()
    for command in commands.values():
        arguments = command["otherArguments"]
        for index, argument in enumerate(arguments):
            if argument != "-load-plugin-executable":
                continue
            value_index = index + 1
            if value_index < len(arguments) and arguments[value_index] == "-Xfrontend":
                value_index += 1
            if value_index >= len(arguments):
                raise ValueError("Missing macro executable argument")
            value = arguments[value_index]
            path, separator, modules = value.rpartition("#")
            if not separator or not modules or not Path(path).is_file():
                raise ValueError("Invalid macro executable argument: " + value)
            plugins.add(value)
    return sorted(plugins)


def runtime_targets(manifest, roots):
    targets = {target["name"]: target for target in manifest["targets"]}
    selected = set()

    def visit(name):
        target = targets.get(name)
        if target is None:
            raise ValueError("Unknown package library target: " + name)
        if target["type"] in ("macro", "plugin"):
            return
        if target["type"] != "regular":
            raise ValueError("Unsupported shipping target kind: " + name + " (" + target["type"] + ")")
        if name in selected:
            return
        selected.add(name)
        for dependency in target.get("dependencies", []):
            local = dependency.get("target") or dependency.get("byName")
            if local:
                visit(local[0])
            elif "product" in dependency:
                raise ValueError("External runtime product needs an explicit link plan: " + str(dependency["product"]))

    for name in sorted(roots):
        visit(name)
    if not roots or not set(roots) <= selected:
        raise ValueError("Expected public runtime library targets")
    return selected


def target_modules(scratch, roots, triple, allow_visionos_plan=False, allowed=None):
    commands, dependencies = {}, {}
    for path in scratch.rglob("description.json"):
        description = json.loads(path.read_text())
        for command in description.get("swiftCommands", {}).values():
            # Host-tool modules can share the destination triple on macOS.
            if Path(command["moduleOutputPath"]).parent != path.parent / "Modules":
                continue
            arguments = command.get("otherArguments", [])
            if "-target" not in arguments or not command.get("isLibrary"):
                continue
            actual = arguments[arguments.index("-target") + 1]
            visionos_plan = (allow_visionos_plan and "-apple-xros" in triple
                             and actual.startswith(triple.split("-apple-xros")[0] + "-apple-xros")
                             and re.fullmatch(r"(?:arm64|x86_64)-apple-xros[0-9.]+(?:-simulator)?", actual)
                             and actual.endswith("-simulator") == triple.endswith("-simulator"))
            if actual != triple and not visionos_plan:
                continue
            name = command["moduleName"]
            if allowed is not None and name not in allowed:
                continue
            if name in commands:
                raise ValueError("Duplicate native target build description: " + name)
            commands[name] = dict(command, actual_target=actual)
            dependencies[name] = description.get("targetDependencyMap", {}).get(name, [])
    selected, visiting, ordered = set(), set(), []

    def visit(name):
        if name in selected:
            return
        if name in visiting or name not in commands:
            raise ValueError("Missing or cyclic shipping module build description: " + name)
        visiting.add(name)
        for dependency in dependencies[name]:
            if dependency in commands:
                visit(dependency)
        visiting.remove(name)
        selected.add(name)
        ordered.append(name)

    for name in sorted(roots):
        visit(name)
    return {name: commands[name] for name in ordered}


def rebuild_visionos(commands, triple, sdk_name, evidence, run):
    """Replace every selected shipping output at the canonical target, in dependency order."""
    observations = []
    if all(command["actual_target"] == triple for command in commands.values()):
        return observations
    if not re.fullmatch(r"(?:arm64|x86_64)-apple-xros[0-9.]+(?:-simulator)?", triple):
        raise ValueError("Canonical rebuild is restricted to visionOS targets")
    for name, command in commands.items():
        arguments = command["otherArguments"][:]
        if (arguments.count("-target") != 1 or "-warnings-as-errors" not in arguments
                or "-swift-version" not in arguments or arguments[arguments.index("-swift-version") + 1] != "6"):
            raise ValueError("Expected strict Swift 6 native module settings for " + name)
        arguments[arguments.index("-target") + 1] = triple
        invocation = ["xcrun", "--sdk", sdk_name, "swiftc", "-module-name", name,
                      "-emit-dependencies", "-emit-module", "-emit-module-path", command["moduleOutputPath"],
                      "-output-file-map", command["outputFileMapPath"], "-c", *command["sources"],
                      "-I", command["importPath"], *arguments]
        observation = run(invocation, evidence / (name + "-canonical-visionos.log"))
        observation.update({"module": name, "native_plan_target": command["actual_target"], "canonical_target": triple})
        observations.append(observation)
        (evidence / "canonical-visionos-rebuild.json").write_text(json.dumps(observations, indent=2) + "\n")
        if observation["exit"] != 0:
            raise RuntimeError("Canonical visionOS shipping module compilation failed: " + name)
    return observations


def validate_outputs(commands, triple):
    observations = {}
    for name, command in commands.items():
        objects = command.get("objects", [])
        if not objects or len(objects) != len(set(objects)) or any(not Path(path).is_file() for path in objects):
            raise ValueError("Missing or duplicate required shipping objects for " + name)
        module = Path(command["moduleOutputPath"])
        if not module.is_file():
            raise ValueError("Missing shipping binary module for " + name)
        serialized = sorted({match.decode() for match in re.findall(
            rb"(?:arm64_32|arm64|x86_64)-apple-(?:macosx|ios|tvos|watchos|xros)[0-9.]+(?:-simulator|-macabi)?", module.read_bytes())})
        if serialized != [triple]:
            raise ValueError("Shipping module serialized target differs from selected floor: " + name + " " + str(serialized))
        observations[name] = {"module": str(module), "serialized_targets": serialized}
    return observations
