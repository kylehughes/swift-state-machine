#!/usr/bin/env python3
"""Compile the G0 language fixtures; all build/evidence output goes outside the checkout."""
import argparse
import hashlib
import json
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT = ROOT.parents[3] / 'Delivery' / 'StateMachine' / 'g0-compiler'
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, default=DEFAULT)
args = parser.parse_args()
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'logs').mkdir(exist_ok=True)
records = []

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(name, command, expected=0, patterns=None, diagnostic_source=None):
    start = time.time()
    try:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        code, log = result.returncode, result.stdout
    except subprocess.TimeoutExpired as exc:
        code, log = 124, str(exc)
    (OUT / 'logs' / (name + '.log')).write_text(log)
    errors = re.findall(r'^(.+?):(\d+):(\d+): error: (.*)$', log, re.M)
    success = code == 0 if expected == 0 else code == 1
    if expected != 0:
        success = success and bool(errors) and not re.search(r'(Stack dump:|Please submit a bug report|Segmentation fault)', log)
        success = success and all(any(re.search(p, error[3]) for p in patterns) for error in errors)
        success = success and all(any(re.search(p, error[3]) for error in errors) for p in patterns)
        success = success and all(pathlib.Path(error[0]).resolve() == diagnostic_source.resolve() for error in errors)
    records.append(dict(name=name, command=list(map(str,command)), command_shell=shlex.join(list(map(str,command))),
                        exit=code, status='pass' if success else 'fail', seconds=time.time()-start,
                        expected_exit='zero' if expected==0 else 'nonzero', diagnostic_patterns=patterns,
                        parsed_errors=errors, log=str(OUT/'logs'/(name+'.log'))))
    print(name, records[-1]['status'], flush=True)
    if not success:
        print(log, flush=True)
    return success

swiftc = subprocess.check_output(['xcrun','--find','swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
flags = [swiftc,'-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',
         '-default-isolation','nonisolated','-target','arm64-apple-macosx13.0','-sdk',sdk]
run('toolchain', [swiftc,'--version'])
run('xcode', ['xcodebuild','-version'])
run('host-system', ['sw_vers'])
run('host-architecture', ['uname','-m'])
sdk_records=[]
source_hashes = {str(p.relative_to(ROOT)):digest(p) for p in ROOT.rglob('*') if p.is_file() and 'Macro' not in p.parts}
core = ROOT/'Sources'/'ProbeCore.swift'
client = ROOT/'Clients'/'Valid.swift'
negative = {
 'CT001': ['used after consume'],
 'CT002': ['consumed more than once'],
 'CT003': ["requires the types 'Idle' and 'Loading' be equivalent"],
 'CT004': ["cannot convert value of type 'String' to expected argument type 'Request'"],
 'CT005': ['consumed more than once'],
 'OperationMismatch': ["cannot convert value of type 'Completion<Save>' to expected argument type 'Completion<Fetch>'"],
 'IsolatedSendable': ["type 'IsolatedValue' does not conform to the 'Sendable' protocol"],
 'ActorCrossing': ["non-Sendable 'IsolatedValue'-typed result can not be returned from main actor-isolated instance method"],
 'SharedNonSendable': ["type 'IsolatedValue' does not conform to the 'Sendable' protocol"],
 'AsyncLock': ['cannot pass function of type .*async.* to parameter expecting synchronous function type'],
 'UniqueLock': ["requires that 'Unique' conform to 'Copyable'"],
 'UniqueResult': ["requires that 'Unique' conform to 'Copyable'"],
 'EscapingConsume': ['noncopyable .* cannot be consumed when captured by an escaping closure'],
}
for mode,opt in [('debug','-Onone'),('release','-O')]:
    directory = OUT/mode
    directory.mkdir(exist_ok=True)
    if not run(mode+'-core', flags+[opt,'-parse-as-library','-enable-library-evolution','-emit-library','-emit-module',
            '-module-name','ProbeCore',core,'-o',directory/'libProbeCore.dylib','-emit-module-path',directory/'ProbeCore.swiftmodule',
            '-emit-module-interface-path',directory/'ProbeCore.swiftinterface']):
        continue
    for isolation in ['nonisolated','MainActor']:
        client_flags = flags.copy()
        client_flags[client_flags.index('-default-isolation')+1] = isolation
        import_flags = ['-I',directory,'-parse-as-library',opt]
        positive_name=mode+'-'+isolation+'-positive'
        if not run(positive_name,client_flags+import_flags+['-c',client,'-o',directory/(isolation+'-positive.o')]):
            continue
        for name,patterns in negative.items():
            path=ROOT/'Negative'/(name+'.swift')
            run(mode+'-'+isolation+'-'+name,client_flags+import_flags+['-c',path,'-o',directory/(isolation+'-'+name+'.o')],
                expected=1,patterns=patterns,diagnostic_source=path)
    run(mode+'-executable',flags+[opt,'-parse-as-library','-I',directory,'-L',directory,'-lProbeCore',
            '-Xlinker','-rpath','-Xlinker',directory,client,ROOT/'Clients'/'Run.swift','-o',directory/'smoke'])
    if (directory/'smoke').exists(): run(mode+'-execute',[directory/'smoke'])
    # Force an interface-only import: no binary Swift module is present in this directory.
    interface_dir=directory/'interface-only'
    interface_dir.mkdir(exist_ok=True)
    shutil.copy2(directory/'ProbeCore.swiftinterface',interface_dir/'ProbeCore.swiftinterface')
    run(mode+'-distribution-import',flags+[opt,'-parse-as-library','-I',interface_dir,'-module-cache-path',interface_dir/'cache',
             '-c',client,'-o',directory/'distribution.o'])
    run(mode+'-dependencies',['otool','-L',directory/'libProbeCore.dylib'])
    run(mode+'-undefined',['nm','-u',directory/'libProbeCore.dylib'])
    run(mode+'-deployment',['xcrun','vtool','-show-build',directory/'libProbeCore.dylib'])

platforms = [
 ('ios-device','iphoneos','arm64-apple-ios16.0'),
 ('ios-simulator','iphonesimulator','arm64-apple-ios16.0-simulator'),
 ('tvos-device','appletvos','arm64-apple-tvos16.0'),
 ('watchos-device','watchos','arm64_32-apple-watchos9.0'),
 ('visionos-device','xros','arm64-apple-xros1.0'),
 ('catalyst','macosx','arm64-apple-ios16.0-macabi'),
]
for name,sdk_name,target in platforms:
    directory=OUT/name
    directory.mkdir(exist_ok=True)
    selected_sdk=subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip()
    sdk_settings=pathlib.Path(selected_sdk)/'SDKSettings.json'
    sdk_records.append(dict(name=sdk_name, path=selected_sdk, target=target, settings_sha256=digest(sdk_settings)))
    platform_flags=flags.copy()
    platform_flags[platform_flags.index('-sdk')+1]=selected_sdk
    platform_flags[platform_flags.index('-target')+1]=target
    if name=='catalyst':
        platform_flags += ['-F',str(pathlib.Path(selected_sdk)/'System/iOSSupport/System/Library/Frameworks'),
                           '-I',str(pathlib.Path(selected_sdk)/'System/iOSSupport/usr/include')]
    if run(name+'-link',platform_flags+['-O','-parse-as-library','-enable-library-evolution','-emit-library','-emit-module',
            '-module-name','ProbeCore',core,'-o',directory/'libProbeCore.dylib',
            '-emit-module-path',directory/'ProbeCore.swiftmodule','-emit-module-interface-path',directory/'ProbeCore.swiftinterface']):
        interface_dir=directory/'interface-only'
        interface_dir.mkdir(exist_ok=True)
        shutil.copy2(directory/'ProbeCore.swiftinterface',interface_dir/'ProbeCore.swiftinterface')
        run(name+'-distribution-import',platform_flags+['-O','-parse-as-library','-I',interface_dir,
                 '-module-cache-path',interface_dir/'cache','-c',client,'-o',directory/'client.o'])
        run(name+'-deployment',['xcrun','vtool','-show-build',directory/'libProbeCore.dylib'])
        run(name+'-dependencies',['otool','-L',directory/'libProbeCore.dylib'])
        run(name+'-undefined',['nm','-u',directory/'libProbeCore.dylib'])

final_hashes = {str(p.relative_to(ROOT)):digest(p) for p in ROOT.rglob('*') if p.is_file() and 'Macro' not in p.parts}
artifacts={str(p.relative_to(OUT)):digest(p) for p in OUT.rglob('*') if p.is_file() and (p.name=='smoke' or p.suffix in ['.o','.dylib','.swiftmodule','.swiftinterface','.swiftdoc','.swiftsourceinfo']) and 'cache' not in p.parts and 'macro' not in p.parts}
report=dict(status='pass' if all(r['status']=='pass' for r in records) and source_hashes==final_hashes else 'fail',
            source_hashes=source_hashes,final_source_hashes=final_hashes,artifacts=artifacts,results=records,sdk_records=sdk_records,
            limitations=['G0 feasibility sources, not production proof.', 'macOS execution is not the required iOS17 runtime execution.',
                         'Platform inspection supplements but does not prove old-runtime compatibility.'])
(OUT/'results.json').write_text(json.dumps(report,indent=2)+'\n')
sys.exit(0 if report['status']=='pass' else 1)
