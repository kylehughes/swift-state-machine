"""Build static DocC with installed Swift/DocC tools and selected public modules."""
import argparse
import json
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

MODULES = ['StateMachine', 'StateMachineUI']
BASE_PATH = 'swift-state-machine'
HIDDEN_KINDS = {"swift.extension"}


def extract_graphs(arguments):
    # Build the real package graph, then extract only the selected public
    # modules. Native SwiftPM's dump command also attempts synthetic test modules.
    from platform_build import PLATFORMS, platform_arguments, rebuild_visionos, runtime_targets, target_modules, validate_outputs
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True, timeout=120))
    shipping = runtime_targets(manifest, MODULES)
    arguments = list(arguments)
    if "--scratch-path" not in arguments:
        Path(".build").mkdir(exist_ok=True)
        arguments += ["--scratch-path", tempfile.mkdtemp(prefix="symbol-graphs-", dir=".build")]
    scratch = Path(arguments[arguments.index("--scratch-path") + 1]).resolve()
    if "--triple" in arguments:
        triple = arguments[arguments.index("--triple") + 1]
        target = re.fullmatch(r"(arm64|x86_64)-apple-(ios|tvos|watchos|xros)([0-9.]+)-(simulator|macabi)", triple)
        if not target:
            raise ValueError("Unsupported documentation simulator target: " + triple)
        architecture, operating_system, floor, environment = target.groups()
        if environment == "macabi" and operating_system != "ios":
            raise ValueError("Mac Catalyst must use an iOS target triple")
        selection = "maccatalyst" if environment == "macabi" else ("visionos" if operating_system == "xros" else operating_system)
        sdk_name = PLATFORMS[selection][1]
        sdk = arguments[arguments.index("--sdk") + 1]
    else:
        floors = [entry["version"] for entry in manifest.get("platforms", []) if entry["platformName"] == "macos"]
        if len(floors) != 1:
            raise ValueError("Expected one declared macOS documentation floor")
        architecture, operating_system, floor = platform.machine(), "macosx", floors[0]
        host = platform_arguments("macos", floor, scratch)
        triple, sdk = host[1], host[3]
        sdk_name, environment = PLATFORMS["macos"][1], None
        arguments += host[:4]
    subprocess.run(["swift", "build", "--build-system", "native"] + arguments, check=True, timeout=600)
    modules = target_modules(scratch, shipping, triple, allow_visionos_plan=operating_system == "xros", allowed=shipping)

    def run(command, log):
        print(json.dumps({"canonical_visionos_command": command}), flush=True)
        with log.open("w") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        print(log.read_text(), end="")
        return {"command": command, "exit": result.returncode, "log": str(log)}

    if operating_system == "xros":
        repairs = rebuild_visionos(modules, triple, sdk_name, scratch, run)
        print(json.dumps({"visionos_native_plan_repairs": repairs}), flush=True)
    validate_outputs(modules, triple)
    directory = Path(tempfile.mkdtemp(prefix="public-symbolgraphs-", dir=scratch))
    imports = sorted({str(Path(module["moduleOutputPath"]).parent) for module in modules.values()})
    expected = tuple(int(value) for value in floor.split("."))
    expected += (0,) * (3 - len(expected))
    for module in MODULES:
        command = ["xcrun", "--sdk", sdk_name, "swift-symbolgraph-extract", "-module-name", module,
                   "-target", triple, "-sdk", sdk, "-minimum-access-level", "public",
                   "-omit-extension-block-symbols", "-output-dir", str(directory)]
        for path in imports:
            command += ["-I", path]
        flags = modules[module]["otherArguments"]
        for index, flag in enumerate(flags):
            if flag in ("-plugin-path", "-external-plugin-path"):
                command += [flag, flags[index + 1]]
        print(json.dumps({"symbol_graph_command": command}), flush=True)
        subprocess.run(command, check=True, timeout=600)
        graph = json.loads((directory / (module + ".symbols.json")).read_text())
        actual = graph["module"]["platform"]
        version = actual["operatingSystem"]["minimumVersion"]
        if (actual["architecture"] != architecture or actual["operatingSystem"]["name"] != operating_system
                or tuple(version.get(part, 0) for part in ("major", "minor", "patch")) != expected
                or actual.get("environment") != environment):
            raise ValueError("Symbol graph platform minimum differs from selected target: " + module)
    return directory


def declared_platforms():
    """Declared non-host Apple platforms, including Mac Catalyst, with their actual floors."""
    from platform_build import PLATFORMS
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True, timeout=120))
    return [(entry["platformName"], entry["version"]) for entry in manifest.get("platforms", [])
            if entry.get("platformName") in PLATFORMS and entry["platformName"] != "macos"]


def simulator_arguments(name, floor, scratch):
    from platform_build import platform_arguments
    return platform_arguments(name, floor, scratch)


def module_graphs(directory, module):
    return list(directory.glob(module + ".symbols.json")) + list(directory.glob(module + "@*.symbols.json"))


def public_symbols(graphs):
    """Maps each module's public symbols, by precise identifier, to readable names across every platform graph."""
    symbols = {module: {} for module in MODULES}
    for target, directory in graphs.items():
        for module in MODULES:
            matches = module_graphs(directory, module)
            if not matches:
                raise ValueError("No public " + target + " symbol graph for " + module)
            for path in matches:
                for symbol in json.loads(path.read_text())["symbols"]:
                    if symbol.get("accessLevel") in ("public", "open") and symbol["kind"]["identifier"] not in HIDDEN_KINDS:
                        name = "/".join(symbol.get("pathComponents") or [symbol["identifier"]["precise"]])
                        symbols[module][symbol["identifier"]["precise"]] = module + "/" + name
    return symbols


class AssetReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()
        self.links = set()

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "a" and attributes.get("href"):
            self.links.add(attributes["href"])
        if tag in ("script", "img", "source") and attributes.get("src"):
            self.paths.add(attributes["src"])
        if tag == "link" and attributes.get("rel") in ("stylesheet", "icon", "preload", "modulepreload"):
            if attributes.get("href"):
                self.paths.add(attributes["href"])


def validate_static_assets(site):
    navigation = site / "index" / "index.json"
    if not navigation.is_file() or not json.loads(navigation.read_text()):
        raise ValueError("Documentation navigation index is missing or empty")
    checked = 0
    for html in site.rglob("*.html"):
        references = AssetReferences()
        references.feed(html.read_text())
        for reference in references.paths:
            url = urlsplit(reference)
            if url.scheme or url.netloc or not url.path:
                continue
            path = unquote(url.path)
            if path.startswith("/"):
                prefix = "/" + BASE_PATH.strip("/") + "/"
                if not path.startswith(prefix):
                    raise ValueError("Asset path omits hosting base path: " + reference)
                asset = site / path.removeprefix(prefix)
            else:
                asset = html.parent / path
            if not asset.resolve().is_relative_to(site.resolve()) or not asset.is_file():
                raise ValueError("Missing documentation asset: " + reference)
            checked += 1
    if not checked:
        raise ValueError("No local static documentation assets were observed")


def validate_internal_links(site):
    """Check rendered topic links and navigation against both JSON and static HTML."""
    checked = set()

    def check(reference):
        url = urlsplit(reference)
        if url.scheme or url.netloc or not url.path:
            return
        path = unquote(url.path)
        prefix = "/" + BASE_PATH.strip("/") + "/"
        if path.startswith(prefix):
            path = "/" + path.removeprefix(prefix)
        if not path.startswith(("/documentation/", "/tutorials/")):
            return
        relative = path.strip("/")
        data = site / "data" / (relative + ".json")
        html = site / relative / "index.html"
        if (not data.resolve().is_relative_to(site.resolve())
                or not data.is_file() or not html.is_file()):
            raise ValueError("Missing internal documentation destination: " + reference)
        checked.add(path)

    def navigation_links(node):
        if isinstance(node, dict):
            if isinstance(node.get("path"), str):
                check(node["path"])
            for child in node.values():
                navigation_links(child)
        elif isinstance(node, list):
            for child in node:
                navigation_links(child)

    navigation_links(json.loads((site / "index" / "index.json").read_text()))
    for path in (site / "data").rglob("*.json"):
        for reference in json.loads(path.read_text()).get("references", {}).values():
            if isinstance(reference.get("url"), str):
                check(reference["url"])
    for html in site.rglob("*.html"):
        references = AssetReferences()
        references.feed(html.read_text())
        for reference in references.links:
            check(reference)
    if not checked:
        raise ValueError("No internal documentation destinations were observed")
    return len(checked)


def validate_site(site, symbols):
    """Requires every module page and a rendered page, by DocC's external identifier, for every public symbol of any platform graph."""
    data = site / "data" / "documentation"
    rendered = {}
    for path in data.rglob("*.json") if data.is_dir() else []:
        page = path.relative_to(data).with_suffix("").as_posix()
        if (site / "documentation" / page / "index.html").is_file():
            identifier = json.loads(path.read_text()).get("metadata", {}).get("externalID")
            if identifier:
                rendered[identifier] = page
    problems = [module for module in MODULES
                if not (data / (module.lower() + ".json")).is_file() or not (site / "documentation" / module.lower() / "index.html").is_file()]
    for module in MODULES:
        names = symbols.get(module, {})
        # Readable names identify the symbol; the precise identifier distinguishes overloads.
        problems += [names[identifier] + " (" + identifier + ")" for identifier in names if identifier not in rendered]
    if problems:
        raise ValueError("Documentation site is missing " + str(len(problems)) + " page(s): " + ", ".join(sorted(problems)[:20]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Documentation output already exists; choose a fresh output")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="docc-", dir=args.output.parent))
    try:
        # Host graphs omit conditional API; extract every declared Apple platform too.
        graphs = {"macos": extract_graphs(["--scratch-path", str(scratch / "macos-build")])}
        platforms = declared_platforms()
        for name, floor in platforms:
            graphs[name] = extract_graphs(simulator_arguments(name, floor, scratch / (name + "-build")))
        symbols = public_symbols(graphs)
        archives = []
        for module in MODULES:
            selected = scratch / module
            for target, directory in graphs.items():
                platform_graphs = selected / target
                platform_graphs.mkdir(parents=True)
                for path in module_graphs(directory, module):
                    shutil.copyfile(path, platform_graphs / path.name)
            catalog = Path("Documentation/" + module + ".docc")
            if not catalog.is_dir():
                raise ValueError("Expected documentation catalog: " + str(catalog))
            archive = scratch / (module + ".doccarchive")
            subprocess.run(["xcrun", "docc", "convert", str(catalog), "--additional-symbol-graph-dir", str(selected),
                            "--output-path", str(archive), "--hosting-base-path", BASE_PATH,
                            "--transform-for-static-hosting", "--warnings-as-errors"], check=True, timeout=600)
            archives.append(archive)
        site = scratch / "site"
        if len(archives) == 1:
            shutil.copytree(archives[0], site)
        else:
            subprocess.run(["xcrun", "docc", "merge"] + [str(path) for path in archives]
                           + ["--output-path", str(site)], check=True, timeout=600)
        validate_site(site, symbols)
        validate_static_assets(site)
        destination = "/" + BASE_PATH.strip("/") + "/documentation/" + (MODULES[0].lower() + "/" if len(MODULES) == 1 else "")
        (site / "index.html").write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=' + destination + '"><a href="' + destination + '">Documentation</a>\n')
        (site / ".nojekyll").touch()
        internal_destinations = validate_internal_links(site)
        try:
            shutil.copytree(site, args.output)
        except BaseException:
            shutil.rmtree(args.output, ignore_errors=True)
            raise
        print(json.dumps({"base_path": BASE_PATH, "modules": MODULES, "platforms": [name for name, _ in platforms],
                          "internal_destinations": internal_destinations, "output": str(args.output)}))
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
