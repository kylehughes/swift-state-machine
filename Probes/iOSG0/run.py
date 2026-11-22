#!/usr/bin/env python3
"""Build with the selected Swift 6.4 compiler, then exercise an owned iOS 17 simulator."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=pathlib.Path)
parser.add_argument('--runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-17-5')
parser.add_argument('--build-only', action='store_true')
args = parser.parse_args()
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
APP = OUT / 'StateMachineG0.app'
APP.mkdir(exist_ok=True)
MODULE = OUT / 'module'
MODULE.mkdir(exist_ok=True)
BUNDLE = 'es.kylehughes.StateMachineG0'
records = []
device = None
result = None
failure = None


def run(name, command, timeout=180):
    command = list(map(str, command))
    try:
        execution = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=timeout)
        code, output = execution.returncode, execution.stdout
    except subprocess.TimeoutExpired as error:
        code, output = 124, str(error)
    log = OUT / (name + '.log')
    log.write_text(output)
    records.append({'name': name, 'command': command, 'exit_status': code, 'log': str(log)})
    if code:
        raise RuntimeError(f'{name} failed ({code}): {output[-3000:]}')
    return output.strip()


try:
    compiler = run('compiler-path', ['xcrun', '--find', 'swiftc'])
    version = run('compiler-version', [compiler, '--version'])
    if 'Swift version 6.4' not in version:
        raise RuntimeError('G0-P07 requires Swift 6.4')
    sdk = run('sdk-path', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    run('xcode-version', ['xcodebuild', '-version'])
    run('sdk-version', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-build-version'])
    flags = [compiler, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
             '-target', 'arm64-apple-ios16.0-simulator', '-sdk', sdk, '-O', '-parse-as-library']
    run('build-core', flags + ['-default-isolation', 'nonisolated', '-module-name', 'ProbeCore',
                              '-emit-module', '-emit-module-path', MODULE / 'ProbeCore.swiftmodule',
                              '-c', ROOT.parent / 'G0/Sources/ProbeCore.swift', '-o', MODULE / 'ProbeCore.o'])
    run('build-app', flags + ['-default-isolation', 'MainActor', '-I', MODULE, ROOT / 'Smoke.swift',
                             MODULE / 'ProbeCore.o', '-o', APP / 'StateMachineG0'])
    info = {'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'StateMachineG0',
            'CFBundleName': 'StateMachineG0', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
            'MinimumOSVersion': '16.0', 'LSRequiresIPhoneOS': True,
            'UIDeviceFamily': [1, 2], 'UILaunchScreen': {}}
    with (APP / 'Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    run('sign', ['codesign', '--force', '--sign', '-', APP])
    run('deployment', ['xcrun', 'vtool', '-show-build', APP / 'StateMachineG0'])
    run('dependencies', ['otool', '-L', APP / 'StateMachineG0'])
    if not args.build_only:
        runtimes = json.loads(run('runtime-inventory', ['xcrun', 'simctl', 'list', 'runtimes', '--json']))
        selected = next((r for r in runtimes['runtimes'] if r['identifier'] == args.runtime), None)
        if not selected or not selected.get('isAvailable') or not selected['version'].startswith('17.'):
            raise RuntimeError('Required iOS 17 runtime is unavailable')
        device = run('create', ['xcrun', 'simctl', 'create', 'StateMachine-G0',
                                'com.apple.CoreSimulator.SimDeviceType.iPhone-15', args.runtime])
        run('boot', ['xcrun', 'simctl', 'boot', device])
        run('boot-status', ['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=180)
        run('install', ['xcrun', 'simctl', 'install', device, APP])
        run('launch', ['xcrun', 'simctl', 'launch', device, BUNDLE])
        container = pathlib.Path(run('container', ['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data']))
        result_path = container / 'Documents/result.json'
        deadline = time.monotonic() + 30
        while not result_path.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if not result_path.exists():
            raise RuntimeError('Smoke result did not arrive within 30 seconds')
        result = json.loads(result_path.read_text())
        (OUT / 'runtime-result.json').write_text(json.dumps(result, indent=2) + '\n')
        if result.get('status') != 'pass' or not result.get('systemVersion', '').startswith('17.'):
            raise RuntimeError(f'Unexpected smoke result: {result}')
        run('terminate', ['xcrun', 'simctl', 'terminate', device, BUNDLE])
except Exception as error:
    failure = str(error)
finally:
    if device:
        for name, command in [('shutdown', ['xcrun', 'simctl', 'shutdown', device]),
                              ('delete', ['xcrun', 'simctl', 'delete', device])]:
            try:
                run(name, command)
            except Exception as error:
                failure = (failure + '\n' if failure else '') + str(error)
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in [ROOT / 'Smoke.swift', ROOT / 'run.py', ROOT.parent / 'G0/Sources/ProbeCore.swift']}
    report = {'probe': 'G0-P07', 'status': 'fail' if failure else ('build-only' if args.build_only else 'pass'),
              'failure': failure, 'commands': records, 'source_sha256': hashes, 'device': device,
              'runtime': result, 'limitations': ['G0 feasibility probe, not production acceptance.']}
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'failure': failure, 'report': str(OUT / 'report.json')}, indent=2))
raise SystemExit(1 if failure else 0)
