#!/usr/bin/env python3
"""Run the isolated G0-P04 macro and external-client compiler fixtures."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
CONFIGURATION = sys.argv[2] if len(sys.argv) > 2 else 'debug'
OPTIMIZATION = '-O' if CONFIGURATION == 'release' else '-Onone'
records = []

def run(name, args, expected=0, location=None, pattern=None):
    try:
        result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=60 if expected else 600)
        output, exit_code = result.stdout, result.returncode
    except subprocess.TimeoutExpired as error:
        output = str(error) + "\n" + str(error.stdout or '')
        exit_code = 'timeout'
    except OSError as error:
        output, exit_code = str(error), 'infrastructure-error'
    (OUT / (name + '.log')).write_text(output)
    diagnostics = re.findall(r'^(.+?):(\d+):(\d+): error: (.+)$', output, re.MULTILINE)
    passed = exit_code == expected
    if expected:
        passed = passed and bool(diagnostics) and all(
            re.search(location, f'{path}:{line}:{column}: error:') and re.search(pattern, message)
            for path, line, column, message in diagnostics)
        passed = passed and not re.search(r'^error:|Stack dump|PLEASE submit a bug report|Program crashed|Assertion failed|Segmentation fault', output, re.MULTILINE)
    records.append(dict(name=name, command=shlex.join(map(str, args)), exit=exit_code,
                        passed=bool(passed), diagnostic_location=location, diagnostic_pattern=pattern,
                        parsed_errors=diagnostics))
    (OUT / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
    if not passed:
        print(output)
        raise SystemExit(f'{name}: unexpected outcome; see {OUT}')
    return output

run('toolchain', ['xcrun', 'swift', '--version'])
run('xcode', ['xcodebuild', '-version'])
run('sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'])
run('release-tag', ['git', 'ls-remote', '--tags', 'https://github.com/swiftlang/swift-syntax.git', 'refs/tags/604.0.0'])
# Native SwiftPM avoids the default Xcode build system's implicit experimental
# DebugDescriptionMacro flag. This option is deprecated by this SwiftPM release.
run('build', ['xcrun', 'swift', 'build', '--build-system', 'native', '--package-path', str(ROOT / 'Consumer'),
              '--scratch-path', str(OUT / 'native-build'), '-c', CONFIGURATION, '-Xswiftc', '-strict-concurrency=complete', '-Xswiftc', '-default-isolation', '-Xswiftc', 'nonisolated', '-v'])
binpath = run('bin-path', ['xcrun', 'swift', 'build', '--build-system', 'native', '--package-path', str(ROOT / 'Consumer'),
                         '--scratch-path', str(OUT / 'native-build'), '-c', CONFIGURATION, '--show-bin-path']).splitlines()[-1]
BIN = Path(binpath)
run('positive-runtime', [str(BIN / 'ExternalConsumer')])
run('runtime-linked-libraries', ['otool', '-L', str(BIN / 'ExternalConsumer')])
run('runtime-undefined-symbols', ['nm', '-u', str(BIN / 'ExternalConsumer')])
checks = {
    'CT006': (2, r"'Domain.Prepared' initializer is inaccessible due to 'fileprivate' protection level"),
    'CT007': (2, r"'Domain.Snapshot' initializer is inaccessible due to 'fileprivate' protection level"),
    'CT008-construct': (2, r"'Domain.Ticket<Operation>' initializer is inaccessible due to 'fileprivate' protection level|'Ticket<Operation>' initializer is inaccessible due to 'fileprivate' protection level"),
    'CT008-mutate': (2, r"'generation' is inaccessible due to 'fileprivate' protection level"),
    'CT009': (2, r"cannot convert value of type .*OperationB.* to expected argument type .*OperationA"),
    'CT010': (4, r"value of type 'Domain' has no member 'prepare'"),
    'CT011': (3, r"'value' is inaccessible due to 'private' protection level"),
}
for name, (line, pattern) in checks.items():
    source = ROOT / 'Negatives' / (name + '.swift')
    run(name, ['xcrun', 'swiftc', OPTIMIZATION, '-swift-version', '6', '-warnings-as-errors', '-strict-concurrency=complete',
               '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0',
               '-I', str(BIN / 'Modules'), '-c', str(source), '-o', str(OUT / (name + '.o'))],
        expected=1, location=re.escape(str(source)) + ':' + str(line) + r':\d+: error:', pattern=pattern)
# Emit textual interfaces into a directory with no binary swiftmodules. Keep
# implementation modules elsewhere so the import checks must rebuild interfaces.
DIST = OUT / 'distribution'
IMPL = OUT / 'interface-implementation'
DIST.mkdir(exist_ok=True)
IMPL.mkdir(exist_ok=True)
common = ['xcrun', 'swiftc', OPTIMIZATION, '-swift-version', '6', '-warnings-as-errors', '-strict-concurrency=complete',
          '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0',
          '-load-plugin-executable', str(BIN / 'DomainPlugin-tool') + '#DomainPlugin']
for name, source in [('DomainMacro', ROOT / 'Sources/DomainMacro/DomainMacro.swift'),
                     ('DomainFixture', ROOT / 'Consumer/Sources/DomainFixture/Domain.swift')]:
    run('interface-' + name, common + ['-I', str(DIST), '-enable-library-evolution',
        '-emit-module', '-module-name', name, '-emit-module-path', str(IMPL / (name + '.swiftmodule')),
        '-emit-module-interface-path', str(DIST / (name + '.swiftinterface')), str(source)])
assert not list(DIST.glob('*.swiftmodule')), 'binary module leaked into interface-only import directory'
run('distribution-positive', common + ['-I', str(DIST), '-c',
    str(ROOT / 'Consumer/Sources/ExternalConsumer/main.swift'), '-o', str(OUT / 'distribution-positive.o')])
distribution_patterns = {
    'CT006': r"'Domain.Prepared' cannot be constructed because it has no accessible initializers",
    'CT007': r"'Domain.Snapshot' cannot be constructed because it has no accessible initializers",
    'CT008-construct': r"'Domain.Ticket<Domain.OperationA>' cannot be constructed because it has no accessible initializers",
    'CT008-mutate': r"value of type 'Domain.Ticket<Domain.OperationA>' has no member 'generation'",
    'CT011': r"value of type 'Domain' has no member 'value'",
}
for name, (line, pattern) in checks.items():
    source = ROOT / 'Negatives' / (name + '.swift')
    pattern = distribution_patterns.get(name, pattern)
    run('distribution-' + name, common + ['-I', str(DIST), '-c', str(source), '-o', str(OUT / ('distribution-' + name + '.o'))],
        expected=1, location=re.escape(str(source)) + ':' + str(line) + r':\d+: error:', pattern=pattern)

lock = ROOT / 'Consumer' / 'Package.resolved'
(OUT / 'Package.resolved').write_bytes(lock.read_bytes())
files = [p for p in ROOT.rglob('*') if p.is_file() and '.build' not in p.parts and '.swiftpm' not in p.parts]
files += [BIN / 'DomainPlugin-tool', BIN / 'ExternalConsumer']
files += list(DIST.glob('*.swiftinterface')) + list(OUT.glob('*.log'))
files += [OUT / 'results.json', OUT / 'Package.resolved', OUT / 'distribution-positive.o']
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(OUT / 'hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
print(f'G0-P04 {CONFIGURATION} passed: external consumer built and ran; binary and interface-only external imports passed controls and seven intended negative object-compilation checks each.')
