"""Create an asserted, hash-matched nonshipping StateMachine source copy."""
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def copy_instrumented(command, destination):
    destination.mkdir(parents=True, exist_ok=False)
    source_dir = destination / 'Sources'
    source_dir.mkdir()
    observations = []
    patch_checks = []
    copied = []
    for original in map(Path, command['sources']):
        text = original.read_text()
        amended = text
        if original.name == 'RetainedAtomic.swift':
            patches = [
                ('import os\n', '''import os
@_silgen_name("performance_clock") private func performanceClock() -> UInt64
@_silgen_name("performance_lock_record") private func performanceRecord(_ kind: UInt32, _ start: UInt64, _ end: UInt64)
public func _performanceCalibrateClock() {
    for _ in 0..<10000 {
        let start = performanceClock()
        let end = performanceClock()
        performanceRecord(3, start, end)
    }
}
'''),
                ('public func load() -> Version { storage.withLock { $0 } }', '''public func load() -> Version {
        let measured = storage.withLock { current in
            let start = performanceClock()
            let result = current
            let end = performanceClock()
            return (result, start, end)
        }
        performanceRecord(0, measured.1, measured.2)
        return measured.0
    }'''),
                ('let result = storage.withLock { $0 === expected }', '''let measured = storage.withLock { current in
            let start = performanceClock()
            let result = current === expected
            let end = performanceClock()
            return (result, start, end)
        }
        performanceRecord(1, measured.1, measured.2)
        let result = measured.0'''),
                ('''let retirement: Version? = storage.withLock { current in
            guard current === expected else { return nil }
            let retired = current
            current = next
            return retired
        }''', '''let measured: (Version?, UInt64, UInt64) = storage.withLock { current in
            let start = performanceClock()
            let retirement: Version?
            if current === expected {
                let retired = current
                current = next
                retirement = retired
            } else {
                retirement = nil
            }
            let end = performanceClock()
            return (retirement, start, end)
        }
        performanceRecord(2, measured.1, measured.2)
        let retirement = measured.0'''),
            ]
            for expected, replacement in patches:
                if amended.count(expected) != 1:
                    raise ValueError('Instrumentation patch no longer matches exactly: ' + expected)
                patch_checks.append({'label': expected.splitlines()[0], 'assertedMatches': 1,
                                     'expectedTextSHA256': hashlib.sha256(expected.encode()).hexdigest()})
                amended = amended.replace(expected, replacement)
            for required in ['return withExtendedLifetime(expected) { result }',
                             'return withExtendedLifetime((expected, next, retirement)) { retirement != nil }']:
                if text.count(required) != 1 or amended.count(required) != 1:
                    raise ValueError('Lifetime extension changed: ' + required)
        output = source_dir / original.name
        output.write_text(amended)
        copied.append(output)
        observations.append({'original': str(original), 'original_sha256': digest(original),
                             'copy': str(output), 'copy_sha256': digest(output), 'instrumented': amended != text})
    if sum(o['instrumented'] for o in observations) != 1:
        raise ValueError('Expected exactly one instrumented source')
    (destination / 'asserted-patches.json').write_text(json.dumps(patch_checks, indent=2) + '\n')
    (destination / 'source-copy.json').write_text(json.dumps(observations, indent=2) + '\n')
    return copied
