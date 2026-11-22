#!/usr/bin/env python3
"""Run external normal-import PT fixtures. Full mode is the exact acceptance matrix, without speed gates."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'Probes/Performance'
sys.path.insert(0, str(ROOT / 'Scripts'))
sys.path.insert(0, str(FIXTURES))
from platform_build import runtime_targets
from instrument_core import copy_instrumented
from instrument_resources import copy_resources


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def identities():
    paths = [ROOT / 'Package.swift', ROOT / 'Package.resolved', ROOT / 'SPEC.md', Path(__file__), ROOT / 'Scripts/check-macro-fixtures.py', ROOT / 'Scripts/platform_build.py']
    paths += [path for name in ['StateMachine', 'StateMachineMacros'] for path in sorted((ROOT / 'Sources' / name).rglob('*.swift'))]
    paths += sorted(FIXTURES.rglob('*'))
    return {str(p.relative_to(ROOT)): digest(p) for p in paths if p.is_file() and '__pycache__' not in str(p)}


class Evidence:
    def __init__(self, directory):
        self.directory = directory
        self.commands = []
        self.base_environment = os.environ.copy()
        self.base_environment.pop("DYLD_INSERT_LIBRARIES", None)
    def run(self, name, command, timeout=600, env=None, allow_failure=False):
        log = self.directory / (name + '.log')
        log.parent.mkdir(parents=True, exist_ok=True)
        start = time.monotonic_ns()
        with log.open('w') as output:
            process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                       env=env if env is not None else self.base_environment, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
        receipt = dict(name=name, command=list(map(str, command)), exit=code, timed_out=timed_out,
                       durationNanoseconds=time.monotonic_ns() - start, timeoutSeconds=timeout, log=str(log),
                       allowFailure=allow_failure, environmentOverrides=({'DYLD_INSERT_LIBRARIES': env['DYLD_INSERT_LIBRARIES']} if env and 'DYLD_INSERT_LIBRARIES' in env else {}))
        self.commands.append(receipt)
        (self.directory / 'commands.json').write_text(json.dumps(self.commands, indent=2) + '\n')
        if timed_out or (code and not allow_failure):
            raise RuntimeError(f'{name} failed (exit {code}, timeout {timed_out}). See {log}')
        return log.read_text()


def percentile(values, p):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * p) - 1)] if values else None


def describe(values):
    return dict(samples=len(values), median=statistics.median(values) if values else None,
                p50=percentile(values, .5), p95=percentile(values, .95), p99=percentile(values, .99))


def summarize(row):
    phases = ['snapshotNanoseconds', 'preparationNanoseconds', 'commitNanoseconds', 'operationNanoseconds', 'settlementNanoseconds']
    by_role = {}
    for role in sorted({p['role'] for p in row['participants']}):
        participants = [p for p in row['participants'] if p['role'] == role]
        by_role[role] = {phase: describe([sample for p in participants for sample in p[phase]]) for phase in phases}
    seconds = row['wallNanoseconds'] / 1e9
    attempts = sum(p['attempts'] for p in row['participants'])
    accepted = sum(p['accepted'] for p in row['participants'])
    result = dict(latencyNanoseconds=by_role, wallSeconds=seconds, attemptedOperationsPerSecond=attempts / seconds,
                  acceptedOperationsPerSecond=accepted / seconds,
                  acceptedInputCommitChangesPerSecond=row["counts"].get("acceptedInputCommits", accepted) / seconds,
                  attempts=attempts, accepted=accepted,
                  conflicts=sum(p['conflicts'] for p in row['participants']),
                  capacityRejections=sum(p['capacityRejections'] for p in row['participants']),
                  otherRejections=sum(p['otherRejections'] for p in row['participants']), explicitRetries=0,
                  counts=row['counts'], memory=row['memory'])
    result['lockBodyNanoseconds'] = {name: describe(samples) for name, samples in row['lockBodyNanoseconds'].items()}
    return result


def aggregate(samples):
    """Keep each repetition and recursively report medians of corresponding scalar results."""
    if not samples:
        return None
    if all(isinstance(v, dict) for v in samples):
        keys = set.intersection(*(set(v) for v in samples))
        return {key: aggregate([v[key] for v in samples]) for key in sorted(keys)}
    if all(isinstance(v, (int, float)) for v in samples):
        return statistics.median(samples)
    return samples[0] if all(v == samples[0] for v in samples) else samples


def select_plan(build_root, manifest):
    allowed = runtime_targets(manifest, {'StateMachine'})
    description = json.loads((build_root / 'description.json').read_text())
    commands = {}
    for command in description.get('swiftCommands', {}).values():
        name = command['moduleName']
        # Native plans include host-tool copies with the same module name/triple.
        # Select observed product Modules, never Modules-tool or a path-name glob for objects.
        if name not in allowed or Path(command['moduleOutputPath']).parent != build_root / 'Modules':
            continue
        if name in commands:
            raise ValueError('Duplicate shipping product module ' + name)
        args = command['otherArguments']
        if '-O' not in args or '-swift-version' not in args or args[args.index('-swift-version') + 1] != '6' or '-warnings-as-errors' not in args:
            raise ValueError('Expected Release strict Swift 6 module: ' + name)
        if '-target' not in args or args[args.index('-target') + 1] != platform.machine() + '-apple-macosx13.0':
            raise ValueError('Expected host macOS 13 product target: ' + name)
        if any('experimental' in a.lower() or 'unchecked' in a.lower() for a in args):
            raise ValueError('Unexpected experimental/concurrency-suppression option')
        commands[name] = command
    if set(commands) != allowed:
        raise ValueError('Incomplete shipping closure: ' + str(allowed - set(commands)))
    for command in commands.values():
        if not command['objects'] or any(not Path(p).is_file() for p in command['objects']):
            raise ValueError('Missing exact native plan object')
    return commands


def freeze_build(build_root, commands, destination):
    destination.mkdir()
    modules = destination / 'Modules'
    modules.mkdir()
    objects = []
    manifest = []
    for name, command in commands.items():
        for original in [Path(command['moduleOutputPath']), *map(Path, command['objects'])]:
            target = modules / original.name if original.suffix == '.swiftmodule' else destination / (name + '-' + original.name)
            before = digest(original)
            shutil.copy2(original, target)
            if digest(original) != before or digest(target) != before:
                raise ValueError('Build changed while copying: ' + str(original))
            manifest.append(dict(original=str(original), frozen=str(target), sha256=before))
            if original.suffix == '.o': objects.append(target)
    plugin = destination / 'StateMachineMacros-tool'
    original = build_root / plugin.name
    before = digest(original)
    shutil.copy2(original, plugin)
    if before != digest(plugin) or before != digest(original): raise ValueError('Plugin changed during copy')
    manifest.append(dict(original=str(original), frozen=str(plugin), sha256=before))
    (destination / 'closure.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # A derived plan retains the original observed flags/dependency selection and maps only
    # artifact locations. It lets later DEVELOPMENT controls reuse this immutable closure.
    location_map = {entry['original']: entry['frozen'] for entry in manifest}
    frozen_commands = {}
    for name, command in commands.items():
        frozen_commands[name] = dict(command, moduleOutputPath=location_map[command['moduleOutputPath']],
                                     importPath=str(modules), objects=[location_map[p] for p in command['objects']],
                                     frozenFromModule=command['moduleOutputPath'])
    (destination / 'description.json').write_text(json.dumps({'swiftCommands': frozen_commands, 'derivedFrozenPlan': True}, indent=2) + '\n')
    return modules, plugin, objects


def instrument(evidence, commands, sdk, shipping_modules, shipping_objects, plugin, resource=False):
    label = 'resource-instrumented' if resource else 'instrumented'
    output = evidence.directory / label
    sources = (copy_resources if resource else copy_instrumented)(commands['StateMachine'], output)
    modules = output / 'Modules'
    modules.mkdir()
    core = output / 'StateMachine.o'
    # Preserve native semantic, target, SDK, warning, package, and optimization options.
    # Redirect outputs and caches, and emit one WMO object instead of per-file parallel output.
    arguments = commands['StateMachine']['otherArguments'][:]
    for flag in ['-num-threads', '-emit-objc-header-path', '-module-cache-path']:
        if flag in arguments:
            index = arguments.index(flag)
            if flag == '-num-threads': del arguments[index:index + 2]
            else: arguments[index + 1] = str(output / ('StateMachine-Swift.h' if flag == '-emit-objc-header-path' else 'ModuleCache'))
    evidence.run(label + '/build-core', ['xcrun', 'swiftc', '-module-name', 'StateMachine', '-emit-module', '-emit-module-path', modules / 'StateMachine.swiftmodule', '-c', *sources, *arguments, '-o', core])
    objects = [p for p in shipping_objects if not p.name.startswith('StateMachine-')] + [core]
    if not resource:
        recorder = output / 'LockRecorder.o'
        evidence.run(label + '/build-recorder', ['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-c', FIXTURES / 'LockRecorder.c', '-o', recorder])
        objects.append(recorder)
    executable = output / 'Performance'
    compile_consumer(evidence, label + '/build-consumer', executable, modules, plugin, objects, sdk,
                     extra=['-D', 'PERFORMANCE_RESOURCE_INSTRUMENTED' if resource else 'PERFORMANCE_LOCK_INSTRUMENTED', '-Xlinker', '-export_dynamic'])
    artifacts = [core, modules / 'StateMachine.swiftmodule', executable]
    if not resource: artifacts.append(recorder)
    (output / 'build-outputs.json').write_text(json.dumps([{'path': str(p), 'sha256': digest(p), 'bytes': p.stat().st_size} for p in artifacts], indent=2) + '\n')
    return executable


def validate_allocator(evidence):
    directory = evidence.directory
    controls = FIXTURES / 'Allocator/Controls'
    for name in ['control', 'entrypoints']:
        executable = directory / ('allocator-' + name)
        evidence.run('allocator-controls/build-' + name, ['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-fno-builtin',
                     '-I', FIXTURES / 'Allocator', controls / (name + '.c'), '-L', directory, '-lAllocationProbe', '-o', executable])
        text = evidence.run('allocator-controls/run-' + name, [executable], timeout=120)
        if name == 'control' and ('serial-held events=10000 bytes=640000 live=10000 live_bytes=640000' not in text or
                                  'concurrent-teardown events=40000 bytes=2560000 live=0 live_bytes=0' not in text):
            raise ValueError('C allocator control mismatch')
    slots = directory / 'swift-slots.o'
    evidence.run('allocator-controls/build-slots', ['xcrun', 'clang', '-O2', '-c', controls / 'swift-slots.c', '-o', slots])
    executable = directory / 'allocator-swift'
    evidence.run('allocator-controls/build-swift', ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                 '-warnings-as-errors', '-O', '-import-objc-header', FIXTURES / 'Allocator/probe.h', controls / 'SwiftControl.swift',
                 slots, '-L', directory, '-lAllocationProbe', '-o', executable])
    text = evidence.run('allocator-controls/run-swift', [executable], timeout=120)
    if ('swift-serial-held events=10000 bytes=240000 live=10000 live_bytes=240000' not in text or
        'swift-serial-teardown events=10000 bytes=240000 live=0 live_bytes=0' not in text or
        'swift-concurrent-teardown' not in text or 'live=0 live_bytes=0' not in text.split('swift-concurrent-teardown')[1]):
        raise ValueError('Swift allocator control mismatch')


def compile_consumer(evidence, name, executable, modules, plugin, objects, sdk, extra=()):
    sources = [FIXTURES / f for f in ['Domain.swift', 'Support.swift', 'Workloads.swift', 'Main.swift']]
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
               '-default-isolation', 'nonisolated', '-target', platform.machine() + '-apple-macosx13.0', '-sdk', sdk,
               '-O', '-parse-as-library', '-I', modules, '-load-plugin-executable', str(plugin) + '#StateMachineMacros',
               '-module-name', 'StateMachinePerformance', '-module-cache-path', executable.parent / 'ConsumerModuleCache', *extra, *sources, *objects, '-o', executable]
    evidence.run(name, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='Fresh external evidence directory')
    parser.add_argument('--mode', choices=['full', 'control'], default='full')
    parser.add_argument('--operations', type=int, help='Development control only. Full mode fixes 10,000 operations')
    parser.add_argument('--control-payload-bytes', type=int, choices=[64, 65536], help='Development control only. Choose one real matrix payload')
    parser.add_argument('--workloads', nargs='+', choices=['pt001', 'pt002', 'pt003', 'pt004', 'pt006', 'lock', 'resource'],
                        default=['pt001', 'pt002', 'pt003', 'pt004', 'pt006', 'lock', 'resource'])
    parser.add_argument('--build-root', type=Path, help='Existing native Release bin path. Build it before selecting its plan')
    parser.add_argument('--reuse-build-root', type=Path, help='Development control only. Skip package build and reuse preliminary Release artifacts')
    parser.add_argument('--scratch-path', type=Path, help='Independent SwiftPM scratch directory (defaults inside external output)')
    args = parser.parse_args()
    if args.mode == 'full' and (args.operations is not None or args.control_payload_bytes is not None or args.reuse_build_root):
        parser.error('Full mode fixes 10,000 operations and requires a current observed native build')
    if args.operations is not None and args.operations < 1: parser.error('Operations must be positive')
    output = args.output.resolve()
    if output.is_relative_to(ROOT): parser.error('Evidence must be outside the package')
    output.mkdir(parents=True, exist_ok=False)
    evidence = Evidence(output)
    initial = identities()
    status = {'status': 'running', 'mode': args.mode, 'finalAcceptanceVerdict': False,
              'operationsPerParticipant': 10000 if args.mode == 'full' else (args.operations or 100),
              'warmupRuns': 1, 'measuredRuns': 5 if args.mode == 'full' else 1,
              'workloads': args.workloads, 'sourceIdentity': initial, 'cells': [], 'macroGraphs': [],
              'limitations': ['No speed threshold or historical comparison.', 'PT005 is N/A while the optional modern backend is absent.',
                              'A supporting benchmark receipt is not a final AC7 verdict.']}
    def save(): (output / 'results.json').write_text(json.dumps(status, indent=2) + '\n')
    save()
    try:
        for name, command in [('swift-version', ['xcrun', 'swift', '--version']), ('xcode-version', ['xcodebuild', '-version']),
                              ('os', ['sw_vers']), ('hardware', ['sysctl', 'hw.model', 'hw.memsize', 'hw.ncpu', 'machdep.cpu.brand_string']),
                              ('git-head', ['git', 'rev-parse', '--verify', 'HEAD']), ('git-status', ['git', 'status', '--porcelain'])]:
            evidence.run('environment/' + name, command, timeout=120, allow_failure=name == 'git-head')
        status['candidateIdentity'] = 'Used-source SHA-256 map. Git HEAD is supplementary and may be absent in this uncommitted checkout.'
        sdk = evidence.run('environment/sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], timeout=120).strip()
        manifest_scratch = args.scratch_path.resolve() if args.scratch_path else (args.build_root.resolve().parent.parent if args.build_root else output / 'swiftpm')
        manifest = json.loads(evidence.run('environment/package', ['swift', 'package', '--scratch-path', manifest_scratch, 'dump-package'], timeout=120))
        if args.reuse_build_root:
            build_root = args.reuse_build_root.resolve()
            status['limitations'].append('Development reuse leaves shipping source and object identity unestablished by a fresh package build.')
        else:
            scratch = args.scratch_path.resolve() if args.scratch_path else (args.build_root.resolve().parent.parent if args.build_root else output / 'swiftpm')
            status['nativeBuildScratch'] = {'path': str(scratch), 'existedBeforeBuild': scratch.exists()}
            evidence.run('build/native-release', ['swift', 'build', '--build-system', 'native', '--configuration', 'release',
                                                '--scratch-path', scratch, '--target', 'StateMachine'])
            build_root = args.build_root.resolve() if args.build_root else scratch / (platform.machine() + '-apple-macosx') / 'release'
        commands = select_plan(build_root, manifest)
        (output / 'selected-plan.json').write_text(json.dumps(commands, indent=2) + '\n')
        modules, plugin, objects = freeze_build(build_root, commands, output / 'shipping-closure')
        executable = output / 'Performance'
        compile_consumer(evidence, 'build/consumer', executable, modules, plugin, objects, sdk)
        status['linkedBenchmark'] = {'path': str(executable), 'bytes': executable.stat().st_size, 'sha256': digest(executable),
                                     'meaning': 'Representative linked macOS benchmark executable, not App Store, download, or install size.'}
        dylib = output / 'libAllocationProbe.dylib'
        evidence.run('build/allocator', ['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-fno-builtin', '-dynamiclib',
                                        FIXTURES / 'Allocator/probe.c', '-o', dylib])
        validate_allocator(evidence)
        instrumented = instrument(evidence, commands, sdk, modules, objects, plugin) if 'lock' in args.workloads else None
        resource_instrumented = instrument(evidence, commands, sdk, modules, objects, plugin, resource=True) if 'resource' in args.workloads else None
        operations = status['operationsPerParticipant']
        sizes = [64, 65536] if args.mode == 'full' else [args.control_payload_bytes or 64]
        status['payloadSizes'] = sizes
        cells = []
        for size in sizes:
            if 'pt001' in args.workloads:
                cells.append(('pt001', size, 1, 0))
                cells.append(('pt001-local', size, 1, 0))
            if 'pt002' in args.workloads:
                for writers in ([1, 4] if args.mode == 'full' else [4]):
                    for readers in ([1, 4] if args.mode == 'full' else [4]): cells.append(('pt002', size, writers, readers))
            for workload in ['pt003', 'pt004']:
                if workload in args.workloads: cells.append((workload, size, 1, 1 if workload == 'pt003' else 0))
        for workload, size, writers, readers in cells:
            for profile in ['latency', 'allocations']:
                label = f'{workload}-{size}B-{writers}w-{readers}r-{profile}'
                cell = dict(label=label, workload=workload, payloadBytes=size, writers=writers, readers=readers, profile=profile, repetitions=[])
                status['cells'].append(cell); save()
                invocation = [executable, '--workload', workload, '--bytes', str(size), '--operations', str(operations),
                              '--writers', str(writers), '--readers', str(readers)]
                env = os.environ.copy()
                # Never inherit external allocation injection into a latency or compiler lane.
                env.pop('DYLD_INSERT_LIBRARIES', None)
                if profile == 'allocations':
                    invocation.append('--allocations'); env['DYLD_INSERT_LIBRARIES'] = str(dylib)
                invocation += ['--repetitions', str(status['measuredRuns'])]
                rows = [json.loads(line) for line in evidence.run('runs/' + label, invocation, env=env).splitlines()]
                if len(rows) != status['measuredRuns'] + 1: raise ValueError('Missing warmup/measured rows')
                for repeat, row in enumerate(rows):
                    if row['payloadBytes'] != size or row['operationsPerParticipant'] != operations: raise ValueError('Wrong workload dimensions')
                    if row['counts']['warmup'] != int(repeat == 0): raise ValueError('Warmup marker mismatch')
                    if repeat > 0: cell['repetitions'].append(summarize(row))
                    save()
                cell['medianAcrossRepetitions'] = aggregate(cell['repetitions']); save()
        if instrumented:
            for size in sizes:
                cell = dict(label=f'pt001-{size}B-lock-body', profile='nonshipping-instrumented-core', repetitions=[])
                status['cells'].append(cell)
                rows = [json.loads(line) for line in evidence.run('runs/' + cell['label'],
                        [instrumented, '--workload', 'pt001', '--bytes', str(size), '--operations', str(operations),
                         '--instrumented', '--repetitions', str(status['measuredRuns'])]).splitlines()]
                if len(rows) != status['measuredRuns'] + 1: raise ValueError('Missing lock warmup/measured rows')
                for repeat, row in enumerate(rows):
                    if not row['lockBodyNanoseconds'].get('load') or not row['lockBodyNanoseconds'].get('install'):
                        raise ValueError('Instrumented lock controls produced no real samples')
                    if repeat > 0: cell['repetitions'].append(summarize(row))
                    save()
                cell['medianAcrossRepetitions'] = aggregate(cell['repetitions']); save()
        if resource_instrumented:
            for size in sizes:
                for workload in ['pt003', 'pt004']:
                    cell = dict(label=f'{workload}-{size}B-resource-copy', profile='nonshipping-resource-copy', repetitions=[])
                    status['cells'].append(cell)
                    rows = [json.loads(line) for line in evidence.run('runs/' + cell['label'],
                            [resource_instrumented, '--workload', workload, '--bytes', str(size), '--operations', str(operations),
                             '--resource-instrumented', '--repetitions', str(status['measuredRuns'])]).splitlines()]
                    if len(rows) != status['measuredRuns'] + 1: raise ValueError('Missing resource warmup/measured rows')
                    for repeat, row in enumerate(rows):
                        if repeat > 0: cell['repetitions'].append(summarize(row))
                        save()
                    cell['medianAcrossRepetitions'] = aggregate(cell['repetitions']); save()
        if 'pt006' in args.workloads:
            graphs = [(2, 1), (32, 128), (128, 512)] if args.mode == 'full' else [(2, 1)]
            for configuration in ['debug', 'release']:
                for phases, edges in graphs:
                    graph = dict(phases=phases, edges=edges, configuration=configuration, repetitions=[])
                    status['macroGraphs'].append(graph)
                    for repeat in range(-1, status['measuredRuns']):
                        name = f'pt006/{configuration}-{phases}-{edges}/' + ('warmup' if repeat == -1 else str(repeat))
                        destination = output / name
                        evidence.run(name + '-driver', ['python3', ROOT / 'Scripts/check-macro-fixtures.py', '--configuration', configuration,
                                                        '--phases', str(phases), '--edges', str(edges), '--build-root', output / 'shipping-closure', '--output', destination], timeout=660)
                        result = json.loads((destination / 'results.json').read_text())
                        if result['status'] != 'pass': raise ValueError('Macro graph did not compile')
                        if repeat >= 0: graph['repetitions'].append(result)
                        save()
                    graph['medianCompileSeconds'] = statistics.median(r['duration_seconds'] for r in graph['repetitions'])
                    graph['medianObjectBytes'] = statistics.median(r['object_bytes'] for r in graph['repetitions'])
                    graph['medianMaximumRSSBytes'] = statistics.median(r['maximum_resident_set_size_bytes'] for r in graph['repetitions'])
                    save()
        final = identities()
        status['sourceIdentityUnchanged'] = final == initial
        if final != initial: raise ValueError('Sources changed during measurement. Samples are preliminary stale-source evidence')
        status['status'] = 'pass'
        status['artifactHashes'] = {str(p.relative_to(output)): digest(p) for p in [executable, dylib, *objects]}
        if instrumented: status['artifactHashes'][str(instrumented.relative_to(output))] = digest(instrumented)
        if resource_instrumented: status['artifactHashes'][str(resource_instrumented.relative_to(output))] = digest(resource_instrumented)
        save()
        print(f'pass ({args.mode}, no AC verdict): {output}')
        return 0
    except Exception as error:
        status['status'] = 'fail'; status['error'] = str(error); save()
        print(f'failed: {error}; evidence: {output}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
