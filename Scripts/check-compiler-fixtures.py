#!/usr/bin/env python3
"""Compile separate-module positive and misuse clients; retain exact commands and diagnostics."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.build/compiler-fixtures')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
records = []


def run(name, command, expected=0, pattern=None, source=None):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    log = output / f'{name}.log'
    log.write_text(result.stdout)
    errors = re.findall(r'^(.+?):(\d+):(\d+): error: (.*)$', result.stdout, re.M)
    passed = result.returncode == expected
    if expected:
        passed = passed and bool(errors) and not re.search(r'Stack dump:|Please submit a bug report|Segmentation fault|no such module', result.stdout)
        passed = passed and any((str(source) == error[0] or (error[0].startswith('macro expansion @') and str(source) in result.stdout)) and re.search(pattern, error[3], re.I) for error in errors)
    records.append(dict(name=name, command=list(map(str, command)), exit=result.returncode, status='pass' if passed else 'fail', log=str(log)))
    return passed


swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
flags = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0', '-sdk', sdk]
run('toolchain', [swiftc, '--version'])
manifest = json.loads((ROOT / 'ClientFixtures/manifest.json').read_text())
for mode in ['debug', 'release']:
    directory = output / mode
    directory.mkdir(exist_ok=True)
    run(f'{mode}-macro-plugin-build', ['swift', 'build', '--build-system', 'native', '--configuration', mode, '--product', 'StateMachineMacros'])
    bin_path = pathlib.Path(subprocess.check_output(['swift', 'build', '--build-system', 'native', '--configuration', mode, '--show-bin-path'], cwd=ROOT, text=True).strip())
    build = flags + (['-O'] if mode == 'release' else ['-Onone']) + ['-load-plugin-executable', str(bin_path / 'StateMachineMacros-tool') + '#StateMachineMacros']
    modules_ready = True
    for module in ['StateMachine', 'StateMachineSchema', 'StateMachineUI', 'StateMachineExamples']:
        sources = sorted((ROOT / 'Sources' / module).glob('*.swift'))
        command = build + ['-package-name', 'StateMachine', '-enable-library-evolution', '-emit-library', '-emit-module', '-module-name', module, '-I', directory, '-L', directory, '-o', directory / f'lib{module}.dylib', '-emit-module-path', directory / f'{module}.swiftmodule', '-emit-module-interface-path', directory / f'{module}.swiftinterface']
        if module != 'StateMachine':
            command += ['-lStateMachine']
        if module == 'StateMachineExamples':
            command += ['-lStateMachineSchema', '-lStateMachineUI']
        modules_ready = run(f'{mode}-{module}', command + sources) and modules_ready
    if not modules_ready:
        continue
    for isolation in ['nonisolated', 'MainActor']:
        client = build.copy()
        client[client.index('-default-isolation') + 1] = isolation
        client += ['-I', directory, '-c']
        for fixture in manifest:
            if fixture.get('status') == 'not-run':
                continue
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
            good = run(stem + '-positive', client + [positive, '-o', directory / f'{isolation}-{identifier}-positive.o'])
            if good:
                run(stem + '-negative', client + [negative, '-o', directory / f'{isolation}-{identifier}-negative.o'], expected=1, pattern=fixture['pattern'], source=negative)
    # Interface-only import is distinct from the normal binary-module lane.
    interfaces = directory / 'interfaces'
    interfaces.mkdir(exist_ok=True)
    for module in ['StateMachine', 'StateMachineSchema', 'StateMachineUI', 'StateMachineExamples']:
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


summary = dict(records=records, fixture_scope=manifest, limits=['CT012/018 prove production raw storage constraints; facade uses same checked storage', 'Generated facade fixtures compile as separate-module clients against actual expansion'], hashes={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted([ROOT / 'Package.swift', ROOT / 'Scripts/check-compiler-fixtures.py', *ROOT.glob('Sources/**/*.swift'), *ROOT.glob('Tests/**/*.swift'), *ROOT.glob('ClientFixtures/**/*.swift'), ROOT / 'ClientFixtures/manifest.json'])})
(output / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
failed = [record['name'] for record in records if record['status'] != 'pass']
print(f'{len(records) - len(failed)}/{len(records)} compiled records passed; final integration limits are recorded in results.json')
if failed:
    print('\n'.join(failed))
sys.exit(bool(failed))
