#!/usr/bin/env python3
"""Compile separate-module positive and misuse clients and retain exact commands and diagnostics."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.build/compiler-fixtures')
parser.add_argument('--jobs', type=int, default=os.cpu_count() or 1, help='client fixture compilations to run at once')
parser.add_argument('--reuse-macro-plugin', action='store_true', help='require the macro plugin from an earlier build of each configuration instead of building it')
parser.add_argument('--fixture', action='append', help='limit client checks to the named fixture ID(s)')
args = parser.parse_args()
manifest = json.loads((ROOT / 'ClientFixtures/manifest.json').read_text())
selected_fixtures = set(args.fixture) if args.fixture else None
if selected_fixtures is not None:
    manifest_by_id = {item['id']: item for item in manifest}
    unknown = sorted(selected_fixtures - manifest_by_id.keys())
    if unknown:
        print(f"Unknown fixture ID(s): {', '.join(unknown)}", file=sys.stderr)
        sys.exit(2)
    selected_manifest = [item for item in manifest if item['id'] in selected_fixtures and item.get('status') != 'not-run']
    if not selected_manifest:
        disabled = sorted(selected_fixtures)
        print(f"Selected fixture ID(s) are all disabled: {', '.join(disabled)}", file=sys.stderr)
        sys.exit(2)
else:
    selected_manifest = manifest
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
# A summary from an earlier run must not describe the logs this run rewrites.
(output / 'results.json').unlink(missing_ok=True)
records = []
CRASH_PATTERN = r'Stack dump:|Please submit a bug report|Segmentation fault|no such module'
PROBE_CRASH_PATTERN = CRASH_PATTERN + r'|Assertion failed:|LLVM ERROR:|Fatal error:|Abort trap|Bus error|Illegal instruction|Trace/BPT trap|due to signal|killed by signal'


def compile_record(name, command, expected=0, pattern=None, source=None, cwd=ROOT):
    log = output / f'{name}.log'
    try:
        result = subprocess.run(list(map(str, command)), cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    except subprocess.TimeoutExpired as expired:
        # A timeout is a failed record that keeps whatever the compiler had printed.
        partial = expired.stdout or ''
        log.write_text((partial.decode(errors='replace') if isinstance(partial, bytes) else partial) + '\ntimed out\n')
        return dict(name=name, command=list(map(str, command)), exit=None, status='fail', log=str(log))
    log.write_text(result.stdout)
    errors = re.findall(r'^(.+?):(\d+):(\d+): error: (.*)$', result.stdout, re.M)
    passed = result.returncode == expected
    if expected:
        passed = passed and bool(errors) and not re.search(CRASH_PATTERN, result.stdout)
        passed = passed and any((str(source) == error[0] or (error[0].startswith('macro expansion @') and str(source) in result.stdout)) and re.search(pattern, error[3], re.I) for error in errors)
    return dict(name=name, command=list(map(str, command)), exit=result.returncode, status='pass' if passed else 'fail', log=str(log))


def probe_record(name, command, pattern, source, cwd=ROOT):
    """Run a compiler-limitation probe that passes on a clean compile or solely the exact known diagnostic."""
    log = output / f'{name}.log'
    try:
        result = subprocess.run(list(map(str, command)), cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    except subprocess.TimeoutExpired as expired:
        partial = expired.stdout or ''
        log.write_text((partial.decode(errors='replace') if isinstance(partial, bytes) else partial) + '\ntimed out\n')
        return dict(name=name, command=list(map(str, command)), exit=None, status='fail', observation='timeout', log=str(log))
    log.write_text(result.stdout)
    crashed = bool(re.search(PROBE_CRASH_PATTERN, result.stdout)) or (result.returncode != 0 and result.returncode != 1)
    all_error_lines = [
        line for line in result.stdout.splitlines()
        if not re.match(r'^\s*\d*\s*\|', line)
        and not re.match(r'^.+?: (?:note|warning|remark): ', line)
        and re.match(r'^(?:error:|.+?: error:)\s', line)
    ]
    if result.returncode == 0 and not crashed and not all_error_lines:
        return dict(name=name, command=list(map(str, command)), exit=0, status='pass', observation='direct-compile-succeeded', log=str(log))
    errors = re.findall(r'^(.+?):(\d+):(\d+): error: (.*)$', result.stdout, re.M)
    matched = (
        result.returncode == 1
        and not crashed
        and bool(errors)
        and len(all_error_lines) == len(errors)
        and all(str(source) == error[0] and re.search(pattern, error[3], re.I) for error in errors)
    )
    if crashed:
        observation = 'crashed'
    elif matched:
        observation = 'known-swift-freestanding-macro-limitation'
    else:
        observation = 'unexpected-diagnostic'
    return dict(
        name=name,
        command=list(map(str, command)),
        exit=result.returncode,
        status='pass' if matched else 'fail',
        observation=observation,
        log=str(log),
    )


def execute_record(name, command, expected_output=None, cwd=ROOT):
    """Execute a linked client fixture binary and verify exit status and expected output."""
    log = output / f'{name}.log'
    try:
        result = subprocess.run(list(map(str, command)), cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    except subprocess.TimeoutExpired as expired:
        partial = expired.stdout or ''
        log.write_text((partial.decode(errors='replace') if isinstance(partial, bytes) else partial) + '\ntimed out\n')
        return dict(name=name, command=list(map(str, command)), exit=None, status='fail', log=str(log))
    log.write_text(result.stdout)
    passed = result.returncode == 0 and (expected_output is None or expected_output in result.stdout)
    return dict(name=name, command=list(map(str, command)), exit=result.returncode, status='pass' if passed else 'fail', log=str(log))


def run(name, command, expected=0, pattern=None, source=None):
    record = compile_record(name, command, expected, pattern, source)
    records.append(record)
    return record['status'] == 'pass'


def check_fixture(mode, directory, isolation, client, fixture, lane='binary', lib_dir=None):
    """Compile one fixture's control and, when it passes, its rejection or probe. Returns their records."""
    identifier = fixture['id']
    positive = ROOT / 'ClientFixtures' / identifier / 'positive.swift'
    negative = ROOT / 'ClientFixtures' / identifier / 'negative.swift'
    additional = [ROOT / path for path in fixture.get('additionalSources', [])]
    if fixture.get('productionSourceAppend'):
        production = (ROOT / fixture['productionSourceAppend']).read_text()
        for kind in ['positive', 'negative']:
            fixture_source = ROOT / 'ClientFixtures' / identifier / f'{kind}.swift'
            combined = directory / f'{isolation}-{identifier}-{kind}-production.swift'
            combined.write_text(production + '\n' + fixture_source.read_text())
            if kind == 'positive':
                positive = combined
            else:
                negative = combined
    prefix = f'{mode}-{isolation}-{identifier}' if lane == 'binary' else f'{mode}-{isolation}-{lane}-{identifier}'
    object_prefix = f'{isolation}-{identifier}' if lane == 'binary' else f'{isolation}-{lane}-{identifier}'
    module_name = 'Fixture_' + re.sub(r'[^A-Za-z0-9_]', '_', identifier)
    results = []
    if fixture.get('executablePositive') and lane == 'binary':
        link_client = [arg for arg in client if arg != '-c']
        executable = directory / f'{object_prefix}-positive'
        link_command = link_client + ['-parse-as-library', '-module-name', module_name, '-L', directory, '-lStateMachine', '-Xlinker', '-rpath', '-Xlinker', directory]
        if lib_dir is not None and fixture.get('libraryModule'):
            link_command += ['-L', lib_dir, f'-l{fixture["libraryModule"]}', '-Xlinker', '-rpath', '-Xlinker', lib_dir]
        link_command += [positive, *additional, '-o', executable]
        results.append(compile_record(prefix + '-positive', link_command))
        if results[0]['status'] == 'pass':
            results.append(execute_record(prefix + '-positive-run', [executable], expected_output=fixture.get('expectedOutput')))
    elif additional:
        case_dir = directory / f'{object_prefix}-positive-objects'
        case_dir.mkdir(exist_ok=True)
        results.append(compile_record(prefix + '-positive', client + ['-parse-as-library', '-module-name', module_name, positive, *additional], cwd=case_dir))
    else:
        results.append(compile_record(prefix + '-positive', client + [positive, '-o', directory / f'{object_prefix}-positive.o']))
    if all(item['status'] == 'pass' for item in results):
        if fixture.get('pattern'):
            if additional:
                case_dir = directory / f'{object_prefix}-negative-objects'
                case_dir.mkdir(exist_ok=True)
                results.append(compile_record(prefix + '-negative', client + ['-parse-as-library', '-module-name', module_name, negative, *additional], expected=1, pattern=fixture['pattern'], source=negative, cwd=case_dir))
            else:
                results.append(compile_record(prefix + '-negative', client + [negative, '-o', directory / f'{object_prefix}-negative.o'], expected=1, pattern=fixture['pattern'], source=negative))
        if fixture.get('probeSource'):
            probe = ROOT / fixture['probeSource']
            probe_dir = directory / f'{object_prefix}-probe-objects'
            probe_dir.mkdir(exist_ok=True)
            results.append(probe_record(prefix + '-probe', client + ['-parse-as-library', '-module-name', module_name, probe, *additional], pattern=fixture['knownCompilerDiagnostic'], source=probe, cwd=probe_dir))
    return results


def build_fixture_library(mode, directory, isolation, build, fixture):
    """Build a fixture-owned separate library module under `isolation` into isolated binary and interface dirs."""
    module = fixture['libraryModule']
    source = ROOT / fixture['librarySource']
    stem = f'{mode}-{isolation}-{fixture["id"]}-library'
    lib_dir = directory / f'fixture-libraries-{isolation}'
    lib_interfaces = directory / f'fixture-interfaces-{isolation}'
    lib_dir.mkdir(exist_ok=True)
    lib_interfaces.mkdir(exist_ok=True)
    library_build = build.copy()
    library_build[library_build.index('-default-isolation') + 1] = isolation
    emitted_interfaces = directory / f'fixture-interfaces-staging-{isolation}'
    emitted_interfaces.mkdir(exist_ok=True)
    command = library_build + [
        '-package-name', 'StateMachine', '-enable-library-evolution', '-emit-library', '-emit-module',
        '-module-name', module, '-I', directory, '-L', directory, '-lStateMachine',
        '-o', lib_dir / f'lib{module}.dylib',
        '-emit-module-path', lib_dir / f'{module}.swiftmodule',
        '-emit-module-interface-path', emitted_interfaces / f'{module}.swiftinterface',
        source,
    ]
    if not run(stem, command):
        return None
    emitted_files = [emitted_interfaces / f'{module}.swiftinterface', emitted_interfaces / f'{module}.private.swiftinterface']
    package_interface = emitted_interfaces / f'{module}.package.swiftinterface'
    if package_interface.is_file():
        emitted_files.append(package_interface)
    leaks = []
    for emitted in emitted_files:
        if not emitted.is_file():
            leaks.append(f'Missing expected interface file: {emitted.name}')
            continue
        text = emitted.read_text()
        for token in fixture.get('forbiddenInterfaceTokens', []):
            if token in text:
                leaks.append(f'Forbidden token {token!r} appeared in {emitted.name}')
        if emitted.name.endswith(('.swiftinterface', '.private.swiftinterface')) and not emitted.name.endswith('.package.swiftinterface'):
            (lib_interfaces / emitted.name).write_bytes(emitted.read_bytes())
    hygiene_log = output / f'{stem}-interface-hygiene.log'
    hygiene_log.write_text('\n'.join(leaks) + ('\n' if leaks else 'ok\n'))
    records.append(dict(
        name=f'{stem}-interface-hygiene',
        command=['check-interface-hygiene', module, isolation],
        exit=1 if leaks else 0,
        status='fail' if leaks else 'pass',
        log=str(hygiene_log),
    ))
    return (lib_dir, lib_interfaces) if not leaks else None


swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
flags = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0', '-sdk', sdk]
run('toolchain', [swiftc, '--version'])
pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs))
for mode in ['debug', 'release']:
    directory = output / mode
    directory.mkdir(exist_ok=True)
    bin_path = pathlib.Path(subprocess.check_output(['swift', 'build', '--build-system', 'native', '--configuration', mode, '--show-bin-path'], cwd=ROOT, text=True).strip())
    if args.reuse_macro_plugin:
        run(f'{mode}-macro-plugin-build', ['test', '-x', bin_path / 'StateMachineMacros-tool'])
    else:
        run(f'{mode}-macro-plugin-build', ['swift', 'build', '--build-system', 'native', '--configuration', mode, '--product', 'StateMachineMacros'])
    build = flags + (['-O'] if mode == 'release' else ['-Onone']) + ['-load-plugin-executable', str(bin_path / 'StateMachineMacros-tool') + '#StateMachineMacros']
    modules_ready = True
    # The examples are not a product. Fixtures import them as the package's own clients do.
    for module in ['StateMachine', 'StateMachineUI', 'StateMachineTesting', 'StateMachineExamples']:
        sources = sorted((ROOT / 'Sources' / module).glob('*.swift'))
        command = build + ['-package-name', 'StateMachine', '-enable-library-evolution', '-emit-library', '-emit-module', '-module-name', module, '-I', directory, '-L', directory, '-o', directory / f'lib{module}.dylib', '-emit-module-path', directory / f'{module}.swiftmodule', '-emit-module-interface-path', directory / f'{module}.swiftinterface']
        if module != 'StateMachine':
            command += ['-lStateMachine']
        if module == 'StateMachineExamples':
            command += ['-lStateMachineUI']
        modules_ready = run(f'{mode}-{module}', command + sources) and modules_ready
    if not modules_ready:
        continue
    # Interface-only import is distinct from the normal binary-module lane.
    interfaces = directory / 'interfaces'
    interfaces.mkdir(exist_ok=True)
    for module in ['StateMachine', 'StateMachineUI', 'StateMachineExamples']:
        (interfaces / f'{module}.swiftinterface').write_bytes((directory / f'{module}.swiftinterface').read_bytes())
        (interfaces / f'{module}.private.swiftinterface').write_bytes((directory / f'{module}.private.swiftinterface').read_bytes())
    # Fixtures are independent of each other, so they compile concurrently. Records keep manifest order.
    pending = []
    for isolation in ['nonisolated', 'MainActor']:
        client = build.copy()
        client[client.index('-default-isolation') + 1] = isolation
        binary_client = client + ['-I', directory, '-c']
        for fixture in selected_manifest:
            if fixture.get('status') == 'not-run':
                continue
            if fixture.get('libraryModule'):
                dirs = build_fixture_library(mode, directory, isolation, build, fixture)
                if not dirs:
                    continue
                lib_dir, lib_interfaces = dirs
                pending.append(pool.submit(check_fixture, mode, directory, isolation, client + ['-I', lib_dir, '-I', directory, '-c'], fixture, 'binary', lib_dir))
                pending.append(pool.submit(check_fixture, mode, directory, isolation, client + ['-I', lib_interfaces, '-I', interfaces, '-c'], fixture, 'interface'))
            else:
                pending.append(pool.submit(check_fixture, mode, directory, isolation, binary_client, fixture, 'binary'))
    try:
        for future in pending:
            records.extend(future.result())
    except BaseException:
        pool.shutdown(cancel_futures=True)
        raise
    if selected_fixtures is None:
        positive = ROOT / 'ClientFixtures/CT-019/positive.swift'
        run(f'{mode}-interface-import', build + ['-I', interfaces, '-c', positive, '-o', directory / 'interface-import.o'])
        owned = ROOT / 'ClientFixtures/CT-001/positive.swift'
        run(f'{mode}-interface-owned-switch', build + ['-I', interfaces, '-c', owned, '-o', directory / 'interface-owned.o'])
        for identifier in ['CT-006', 'CT-011']:
            fixture = next(item for item in manifest if item['id'] == identifier)
            negative = ROOT / 'ClientFixtures' / identifier / 'negative.swift'
            run(f'{mode}-interface-{identifier}-sealing', build + ['-I', interfaces, '-c', negative, '-o', directory / f'interface-{identifier}.o'], expected=1, pattern=fixture['pattern'], source=negative)

pool.shutdown()

summary = dict(records=records, fixture_scope=selected_manifest, limits=['CT012/018 prove production raw storage constraints. The facade uses the same checked storage.', 'Generated facade fixtures compile as separate-module clients against actual expansion.'], hashes={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted([ROOT / 'Package.swift', ROOT / 'Scripts/check-compiler-fixtures.py', *ROOT.glob('Sources/**/*.swift'), *ROOT.glob('Tests/**/*.swift'), *ROOT.glob('ClientFixtures/**/*.swift'), ROOT / 'ClientFixtures/manifest.json'])})
(output / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
failed = [record['name'] for record in records if record['status'] != 'pass']
print(f'{len(records) - len(failed)}/{len(records)} compiled records passed. Final integration limits are recorded in results.json')
if failed:
    print('\n'.join(failed))
sys.exit(bool(failed))
