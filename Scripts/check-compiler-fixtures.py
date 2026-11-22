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
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
# A summary from an earlier run must not describe the logs this run rewrites.
(output / 'results.json').unlink(missing_ok=True)
records = []


def compile_record(name, command, expected=0, pattern=None, source=None):
    log = output / f'{name}.log'
    try:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    except subprocess.TimeoutExpired as expired:
        # A timeout is a failed record that keeps whatever the compiler had printed.
        partial = expired.stdout or ''
        log.write_text((partial.decode(errors='replace') if isinstance(partial, bytes) else partial) + '\ntimed out\n')
        return dict(name=name, command=list(map(str, command)), exit=None, status='fail', log=str(log))
    log.write_text(result.stdout)
    errors = re.findall(r'^(.+?):(\d+):(\d+): error: (.*)$', result.stdout, re.M)
    passed = result.returncode == expected
    if expected:
        passed = passed and bool(errors) and not re.search(r'Stack dump:|Please submit a bug report|Segmentation fault|no such module', result.stdout)
        passed = passed and any((str(source) == error[0] or (error[0].startswith('macro expansion @') and str(source) in result.stdout)) and re.search(pattern, error[3], re.I) for error in errors)
    return dict(name=name, command=list(map(str, command)), exit=result.returncode, status='pass' if passed else 'fail', log=str(log))


def run(name, command, expected=0, pattern=None, source=None):
    record = compile_record(name, command, expected, pattern, source)
    records.append(record)
    return record['status'] == 'pass'


def check_fixture(mode, directory, isolation, client, fixture):
    """Compile one fixture's control and, when it passes, its rejection. Returns their records."""
    identifier = fixture['id']
    positive = ROOT / 'ClientFixtures' / identifier / 'positive.swift'
    negative = ROOT / 'ClientFixtures' / identifier / 'negative.swift'
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
    stem = f'{mode}-{isolation}-{identifier}'
    results = [compile_record(stem + '-positive', client + [positive, '-o', directory / f'{isolation}-{identifier}-positive.o'])]
    if results[0]['status'] == 'pass':
        results.append(compile_record(stem + '-negative', client + [negative, '-o', directory / f'{isolation}-{identifier}-negative.o'], expected=1, pattern=fixture['pattern'], source=negative))
    return results


swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
flags = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0', '-sdk', sdk]
run('toolchain', [swiftc, '--version'])
manifest = json.loads((ROOT / 'ClientFixtures/manifest.json').read_text())
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
    # Fixtures are independent of each other, so they compile concurrently. Records keep manifest order.
    pending = []
    for isolation in ['nonisolated', 'MainActor']:
        client = build.copy()
        client[client.index('-default-isolation') + 1] = isolation
        client += ['-I', directory, '-c']
        for fixture in manifest:
            if fixture.get('status') != 'not-run':
                pending.append(pool.submit(check_fixture, mode, directory, isolation, client, fixture))
    try:
        for future in pending:
            records.extend(future.result())
    except BaseException:
        pool.shutdown(cancel_futures=True)
        raise
    # Interface-only import is distinct from the normal binary-module lane.
    interfaces = directory / 'interfaces'
    interfaces.mkdir(exist_ok=True)
    for module in ['StateMachine', 'StateMachineUI', 'StateMachineExamples']:
        (interfaces / f'{module}.swiftinterface').write_bytes((directory / f'{module}.swiftinterface').read_bytes())
        (interfaces / f'{module}.private.swiftinterface').write_bytes((directory / f'{module}.private.swiftinterface').read_bytes())
    positive = ROOT / 'ClientFixtures/CT-019/positive.swift'
    run(f'{mode}-interface-import', build + ['-I', interfaces, '-c', positive, '-o', directory / 'interface-import.o'])
    owned = ROOT / 'ClientFixtures/CT-001/positive.swift'
    run(f'{mode}-interface-owned-switch', build + ['-I', interfaces, '-c', owned, '-o', directory / 'interface-owned.o'])
    for identifier in ['CT-006', 'CT-011']:
        fixture = next(item for item in manifest if item['id'] == identifier)
        negative = ROOT / 'ClientFixtures' / identifier / 'negative.swift'
        run(f'{mode}-interface-{identifier}-sealing', build + ['-I', interfaces, '-c', negative, '-o', directory / f'interface-{identifier}.o'], expected=1, pattern=fixture['pattern'], source=negative)

pool.shutdown()

summary = dict(records=records, fixture_scope=manifest, limits=['CT012/018 prove production raw storage constraints. The facade uses the same checked storage.', 'Generated facade fixtures compile as separate-module clients against actual expansion.'], hashes={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted([ROOT / 'Package.swift', ROOT / 'Scripts/check-compiler-fixtures.py', *ROOT.glob('Sources/**/*.swift'), *ROOT.glob('Tests/**/*.swift'), *ROOT.glob('ClientFixtures/**/*.swift'), ROOT / 'ClientFixtures/manifest.json'])})
(output / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
failed = [record['name'] for record in records if record['status'] != 'pass']
print(f'{len(records) - len(failed)}/{len(records)} compiled records passed. Final integration limits are recorded in results.json')
if failed:
    print('\n'.join(failed))
sys.exit(bool(failed))
