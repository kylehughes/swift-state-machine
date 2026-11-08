#!/usr/bin/env python3
"""Compile real macro clients and compare deterministic tracked expansion snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--record', action='store_true')
parser.add_argument('--configuration', choices=('debug', 'release'), default='debug')
parser.add_argument('--fixtures', type=Path, default=ROOT / 'ClientFixtures/MacroSnapshots')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
sources = [source for source in sorted(args.fixtures.glob('*.swift')) if not source.name.endswith('.expanded.swift')]
if not sources:
    parser.error('No macro snapshot input sources were selected')
bin_path = Path(subprocess.check_output(['swift', 'build', '--build-system', 'native', '--configuration', args.configuration, '--show-bin-path'], cwd=ROOT, text=True).strip())
swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
records = []
for source in sources:
    command = [swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-default-isolation', 'nonisolated', '-O' if args.configuration == 'release' else '-Onone', '-sdk', sdk, '-target', 'arm64-apple-macosx13.0', '-I', str(bin_path / 'Modules'), '-load-plugin-executable', str(bin_path / 'StateMachineMacros-tool') + '#StateMachineMacros', '-Xfrontend', '-dump-macro-expansions', '-c', str(source), '-o', str(output / (source.stem + '.o'))]
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    (output / (source.stem + '.log')).write_text(result.stdout)
    lines = result.stdout.splitlines()
    blocks = []
    for index, line in enumerate(lines):
        if line.startswith('@__swiftmacro_') and 'StateMachinefMm_' in line:
            end = next(i for i in range(index + 2, len(lines)) if lines[i].startswith('----------------'))
            blocks.append('\n'.join(lines[index + 2:end]) + '\n')
    actual = ''.join(blocks)
    snapshot = source.with_suffix('.expanded.swift')
    if args.record and result.returncode == 0 and actual:
        snapshot.write_text(actual)
    matched = snapshot.exists() and actual.encode() == snapshot.read_bytes()
    records.append(dict(source=str(source.resolve()), configuration=args.configuration, command=command, exit_code=result.returncode, duration_seconds=time.monotonic() - started, expansion_sha256=hashlib.sha256(actual.encode()).hexdigest(), matched=matched, status='pass' if result.returncode == 0 and actual and matched else 'fail'))
(output / 'results.json').write_text(json.dumps(dict(configuration=args.configuration, records=records), indent=2) + '\n')
print(f"{sum(r['status'] == 'pass' for r in records)}/{len(records)} expansion snapshots passed")
raise SystemExit(any(r['status'] != 'pass' for r in records))
