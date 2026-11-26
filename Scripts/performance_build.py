"""Shared native Release build selection, closure freezing, and command evidence helpers."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import time

from platform_build import runtime_targets


def digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Evidence:
    def __init__(self, directory: Path, root: Path):
        self.directory = directory
        self.root = root
        self.commands = []
        self.base_environment = os.environ.copy()
        self.base_environment.pop("DYLD_INSERT_LIBRARIES", None)

    def run(self, name: str, command, timeout: int = 600, env=None, allow_failure: bool = False) -> str:
        log = self.directory / (name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        start = time.monotonic_ns()
        with log.open("w") as output:
            process = subprocess.Popen(
                list(map(str, command)),
                cwd=self.root,
                stdout=output,
                stderr=subprocess.STDOUT,
                env=env if env is not None else self.base_environment,
                start_new_session=True,
            )
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
        receipt = dict(
            name=name,
            command=list(map(str, command)),
            exit=code,
            timed_out=timed_out,
            durationNanoseconds=time.monotonic_ns() - start,
            timeoutSeconds=timeout,
            log=str(log),
            allowFailure=allow_failure,
            environmentOverrides=(
                {"DYLD_INSERT_LIBRARIES": env["DYLD_INSERT_LIBRARIES"]}
                if env and "DYLD_INSERT_LIBRARIES" in env
                else {}
            ),
        )
        self.commands.append(receipt)
        (self.directory / "commands.json").write_text(json.dumps(self.commands, indent=2) + "\n")
        if timed_out or (code and not allow_failure):
            raise RuntimeError(f"{name} failed (exit {code}, timeout {timed_out}). See {log}")
        return log.read_text()


def select_plan(build_root: Path, manifest: dict) -> dict:
    allowed = runtime_targets(manifest, {"StateMachine"})
    description = json.loads((build_root / "description.json").read_text())
    commands = {}
    for command in description.get("swiftCommands", {}).values():
        name = command["moduleName"]
        # Native plans include host-tool copies with the same module name/triple.
        # Select observed product Modules, never Modules-tool or a path-name glob for objects.
        if name not in allowed or Path(command["moduleOutputPath"]).parent != build_root / "Modules":
            continue
        if name in commands:
            raise ValueError("Duplicate shipping product module " + name)
        args = command["otherArguments"]
        if (
            "-O" not in args
            or "-swift-version" not in args
            or args[args.index("-swift-version") + 1] != "6"
            or "-warnings-as-errors" not in args
        ):
            raise ValueError("Expected Release strict Swift 6 module: " + name)
        if "-target" not in args or args[args.index("-target") + 1] != platform.machine() + "-apple-macosx13.0":
            raise ValueError("Expected host macOS 13 product target: " + name)
        if any("experimental" in a.lower() or "unchecked" in a.lower() for a in args):
            raise ValueError("Unexpected experimental/concurrency-suppression option")
        commands[name] = command
    if set(commands) != allowed:
        raise ValueError("Incomplete shipping closure: " + str(allowed - set(commands)))
    for command in commands.values():
        if not command["objects"] or any(not Path(p).is_file() for p in command["objects"]):
            raise ValueError("Missing exact native plan object")
    if not (build_root / "StateMachineMacros-tool").is_file():
        raise ValueError("Missing matching macro plugin executable: " + str(build_root / "StateMachineMacros-tool"))
    return commands


def freeze_build(build_root: Path, commands: dict, destination: Path):
    destination.mkdir()
    modules = destination / "Modules"
    modules.mkdir()
    objects = []
    manifest = []
    for name, command in commands.items():
        for original in [Path(command["moduleOutputPath"]), *map(Path, command["objects"])]:
            target = (
                modules / original.name
                if original.suffix == ".swiftmodule"
                else destination / (name + "-" + original.name)
            )
            before = digest(original)
            shutil.copy2(original, target)
            if digest(original) != before or digest(target) != before:
                raise ValueError("Build changed while copying: " + str(original))
            manifest.append(dict(original=str(original), frozen=str(target), sha256=before))
            if original.suffix == ".o":
                objects.append(target)
    plugin = destination / "StateMachineMacros-tool"
    original = build_root / plugin.name
    before = digest(original)
    shutil.copy2(original, plugin)
    if before != digest(plugin) or before != digest(original):
        raise ValueError("Plugin changed during copy")
    manifest.append(dict(original=str(original), frozen=str(plugin), sha256=before))
    (destination / "closure.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # A derived plan retains the original observed flags/dependency selection and maps only
    # artifact locations. It lets later DEVELOPMENT controls reuse this immutable closure.
    location_map = {entry["original"]: entry["frozen"] for entry in manifest}
    frozen_commands = {}
    for name, command in commands.items():
        frozen_commands[name] = dict(
            command,
            moduleOutputPath=location_map[command["moduleOutputPath"]],
            importPath=str(modules),
            objects=[location_map[p] for p in command["objects"]],
            frozenFromModule=command["moduleOutputPath"],
        )
    (destination / "description.json").write_text(
        json.dumps({"swiftCommands": frozen_commands, "derivedFrozenPlan": True}, indent=2) + "\n"
    )
    return modules, plugin, objects
