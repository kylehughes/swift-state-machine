"""Regression controls for task-construction coverage without a package or Swift build."""
import json
from pathlib import Path
import tempfile
import unittest
from instrument_resources import SEQUENCE_EXCLUSIONS, assert_shared_fixture_scope, copy_resources, task_constructions, track

SOURCES = Path(__file__).resolve().parents[2] / 'Sources/StateMachine'


class TaskInventoryTests(unittest.TestCase):
    def test_generic_detached_parenthesized_and_nested_constructions_are_wrapped(self):
        source = '''let parent = Swift.Task<Void, Never>(priority: nil) {
    let child = Task<Void, Never>.detached(priority: .background, operation: { })
    await child.value
}
let explicit = Task<Void, Never>.init(operation: { })
'''
        sites = task_constructions(source)
        self.assertEqual([(s['kind'], s['generic'], s['nestingDepth']) for s in sites],
                         [('Task', True, 0), ('Task.detached', True, 1), ('Task.init', True, 0)])
        rewritten = track(source, 3)
        self.assertEqual(rewritten.count('RuntimeCoordinatorTaskProbe.keep('), 3)
        self.assertIn('keep(Swift.Task<Void, Never>', rewritten)
        self.assertNotIn('Swift.RuntimeCoordinatorTaskProbe', rewritten)
        self.assertEqual(len(task_constructions(rewritten)), 3)

    def test_type_annotations_comments_strings_and_task_operations_are_not_constructors(self):
        source = '''let worker: Task<Int, Never>
var watcher: Task<Void, Never>?
// Task.detached { bogus }
/* outer /* Task { bogus } */ comment */
let text = #"Task { text }"#
let multiline = """Task.detached { text }"""
await Task.yield()
try? await Task.sleep(until: deadline, clock: ContinuousClock())
if Task.isCancelled { return }
'''
        self.assertEqual(task_constructions(source), [])
        self.assertEqual(track(source, 0), source)

    def test_constructor_count_changes_and_unknown_spellings_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'Task site drift'):
            track('Task { Task.detached { } }', 1)
        for source in ['Task.unknown { }', 'let constructor = Task.detached',
                       r'let text = "\(Task { })"', '`Task` { }', 'async let child = work()', 'typealias Worker = Task<Void, Never>', 'await withTaskGroup(of: Int.self) { group in }']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                task_constructions(source)

    def test_snapshot_wait_exclusion_preflight_and_fail_closed_drift(self):
        self.assertEqual(SEQUENCE_EXCLUSIONS['SnapshotWait.swift'], {'Task': 1})
        assert_shared_fixture_scope()
        sources = sorted(SOURCES.glob('*.swift'))
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / 'resource-copy'
            copy_resources({'sources': [str(p) for p in sources]}, destination)
            patches = {p['file']: p for p in json.loads((destination / 'asserted-patches.json').read_text())}
            self.assertEqual(patches['SnapshotWait.swift']['excludedTaskSites'], 1)
            self.assertEqual(patches['SnapshotWait.swift']['constructorKinds'], {'Task': 1})
            self.assertEqual(
                (destination / 'Sources/SnapshotWait.swift').read_bytes(),
                (SOURCES / 'SnapshotWait.swift').read_bytes(),
            )

            # Mutated SnapshotWait.swift with an extra task site must fail closed.
            drifted_dir = Path(tmp) / 'drifted-src'
            drifted_dir.mkdir()
            drifted_sources = []
            for path in sources:
                if path.name == 'SnapshotWait.swift':
                    drifted = drifted_dir / 'SnapshotWait.swift'
                    drifted.write_text(path.read_text() + '\nfunc extra() { _ = Task { } }\n')
                    drifted_sources.append(str(drifted))
                else:
                    drifted_sources.append(str(path))
            with self.assertRaisesRegex(ValueError, 'Excluded sequence Task inventory drift: SnapshotWait.swift'):
                copy_resources({'sources': drifted_sources}, Path(tmp) / 'drifted-out')


if __name__ == '__main__':
    unittest.main()
