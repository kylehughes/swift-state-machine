"""Regression controls for task-construction coverage; no package or Swift build."""
import unittest
from instrument_resources import task_constructions, track


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


if __name__ == '__main__':
    unittest.main()
