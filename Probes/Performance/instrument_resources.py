"""Create a nonshipping resource copy with registered task joins and preparation counters."""
import hashlib
import json
from pathlib import Path
from instrument_core import digest

# Retain task handles in an atomically replaced registry, then drain and await each cohort until empty.
REGISTRY = '''
public enum RuntimeCoordinatorTaskProbe {
    private static let tasks = AtomicRecordStorage<[Task<Void, Never>]>([])
    @discardableResult public static func keep(_ task: Task<Void, Never>) -> Task<Void, Never> {
        while true {
            let before = tasks.load()
            if tasks.install(.init(before.value + [task]), replacing: before) { return task }
        }
    }
    public static var trackedCount: Int { tasks.load().value.count }
    public static func join() async {
        while true {
            let before = tasks.load()
            if before.value.isEmpty { return }
            guard tasks.install(.init([]), replacing: before) else { continue }
            for task in before.value { await task.value }
        }
    }
}
public final class RuntimeHostWeakProbe {
    private weak var value: AnyObject?
    /// Whether the object is an actor, which the concurrency runtime can still hold for a moment after
    /// the last job that ran on it has returned and every task that referenced it has been joined.
    public let isActor: Bool
    public init(_ value: AnyObject) {
        self.value = value
        isActor = value is any Actor
    }
    public var isAlive: Bool { value != nil }
}
'''


def swift_tokens(text):
    """Return token offsets for task inventory while skipping comments and strings.

    This is a bounded lexical scanner rather than a Swift semantic parser. Unknown Task
    members and constructor spellings fail closed, and Task-bearing string interpolation
    raises an error rather than being silently omitted.
    """
    tokens = []
    i = 0
    while i < len(text):
        if text[i].isspace(): i += 1; continue
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
            continue
        if text.startswith('/*', i):
            depth = 1; i += 2
            while depth and i < len(text):
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            if depth: raise ValueError('Unterminated Swift block comment')
            continue
        string_start = i
        hashes = 0
        while i + hashes < len(text) and text[i + hashes] == '#': hashes += 1
        quote = i + hashes
        if quote < len(text) and text[quote] == '"':
            delimiter = '"""' if text.startswith('"""', quote) else '"'
            closing = delimiter + '#' * hashes
            i = quote + len(delimiter)
            while i < len(text):
                if text.startswith(closing, i):
                    i += len(closing); break
                if text[i] == '\\': i += 2
                else: i += 1
            else: raise ValueError('Unterminated Swift string')
            literal = text[string_start:i]
            if 'Task' in literal and '\\' + '#' * hashes + '(' in literal:
                raise ValueError('Task-bearing string interpolation needs explicit inventory support')
            continue
        start = i
        if text[i].isalpha() or text[i] == '_':
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == '_'): i += 1
        else: i += 1
        tokens.append((text[start:i], start, i))
    return tokens


def task_constructions(text):
    """Inventory trailing-closure and parenthesized Task/init/detached calls, including nested calls."""
    tokens = swift_tokens(text)
    sites = []
    spellings = [token for token, _, _ in tokens]
    declaration_starts = {'func', 'var', 'let', 'class', 'actor', 'struct', 'enum', 'typealias', 'extension'}
    for index, spelling in enumerate(spellings):
        if spelling != 'typealias': continue
        end = index + 1
        while end < len(spellings) and spellings[end] not in declaration_starts: end += 1
        if 'Task' in spellings[index + 1:end]:
            raise ValueError('Task type aliases need explicit inventory/join support')
    unsupported_creation = {'withTaskGroup', 'withThrowingTaskGroup', 'withDiscardingTaskGroup',
                            'withThrowingDiscardingTaskGroup', 'addTask', 'addTaskUnlessCancelled'}
    if unsupported_creation.intersection(spellings) or any(spellings[i:i + 2] == ['async', 'let'] for i in range(len(spellings) - 1)):
        raise ValueError('Structured task creation needs explicit inventory/join support')
    def balanced(index, opening, closing):
        depth = 0
        for end in range(index, len(tokens)):
            token = tokens[end][0]
            if token == opening: depth += 1
            elif token == closing:
                depth -= 1
                if depth == 0: return end + 1
        raise ValueError('Unbalanced Task expression')
    known_members = {'yield', 'sleep', 'isCancelled', 'checkCancellation', 'currentPriority', 'basePriority'}
    for index, (token, start, _) in enumerate(tokens):
        if token != 'Task': continue
        if (index and tokens[index - 1][0] == '`') or (index + 1 < len(tokens) and tokens[index + 1][0] == '`'):
            raise ValueError('Escaped Task identifier requires explicit inventory support')
        j = index + 1
        generic = j < len(tokens) and tokens[j][0] == '<'
        if generic: j = balanced(j, '<', '>')
        kind = 'Task'
        if j < len(tokens) and tokens[j][0] == '.':
            member = tokens[j + 1][0] if j + 1 < len(tokens) else ''
            if member in known_members: continue
            if member not in {'detached', 'init'}:
                raise ValueError('Unrecognized Task member: ' + member)
            kind += '.' + member
            j += 2
        if j >= len(tokens):
            if kind != 'Task': raise ValueError('Uninvoked Task constructor reference requires explicit support')
            continue
        if tokens[j][0] not in {'(', '{'}:
            if kind != 'Task': raise ValueError('Uninvoked Task constructor reference requires explicit support')
            continue  # A Task type annotation, including Task<Void, Never>?.
        if index >= 2 and tokens[index - 1][0] == '.':
            if tokens[index - 2][0] != 'Swift': raise ValueError('Task is qualified by an unrecognized namespace')
            start = tokens[index - 2][1]
        if tokens[j][0] == '(':
            j = balanced(j, '(', ')')
        if j < len(tokens) and tokens[j][0] == '{':
            j = balanced(j, '{', '}')
        if j == 0: raise ValueError('Empty Task construction')
        end = tokens[j - 1][2]
        sites.append({'start': start, 'end': end, 'line': text.count('\n', 0, start) + 1,
                      'kind': kind, 'generic': generic,
                      'expression_sha256': hashlib.sha256(text[start:end].encode()).hexdigest()})
    for site in sites:
        site['nestingDepth'] = sum(other['start'] < site['start'] and site['end'] <= other['end'] for other in sites)
    return sites


def track(text, expected):
    sites = task_constructions(text)
    if len(sites) != expected:
        raise ValueError(f'Task site drift: expected {expected}, got {len(sites)}')
    # Boundary insertion handles overlapping/nested Task expressions without dropping a child.
    boundaries = {}
    for site in sites:
        boundaries.setdefault(site['start'], [0, 0])[1] += 1
        boundaries.setdefault(site['end'], [0, 0])[0] += 1
    pieces, cursor = [], 0
    for position, (ends, starts) in sorted(boundaries.items()):
        pieces += [text[cursor:position], ')' * ends, 'RuntimeCoordinatorTaskProbe.keep(' * starts]
        cursor = position
    pieces.append(text[cursor:])
    return ''.join(pieces)


CONFINED_EXCLUSIONS = {
    'RuntimeActorHost.swift': {'Task': 2, 'Task.detached': 8},
    'RuntimeMainActorHost.swift': {'Task': 8},
    'RuntimeConfinedSupport.swift': {'Task': 1},
    'RuntimeIsolatedHost.swift': {'Task': 6},
}
CONFINED_TYPES = {'RuntimeActorHost', 'RuntimeMainActorHost', 'RuntimeIsolatedHost', 'MainActorSnapshotSubscription',
                  'RuntimeConfinedExecution'}
# Main-actor teardown, wakeup, and bounded-wait deadline-timer tasks of snapshot sequences and Combine
# publishers. The benchmark registers callback subscriptions only, so it never creates a sequence,
# calls `SnapshotSequence.wait`, or starts one of these tasks.
SEQUENCE_EXCLUSIONS = {
    'RuntimeSnapshots.swift': {'Task': 5},
    'SnapshotPublisher.swift': {'Task': 6},
    'SnapshotWait.swift': {'Task': 1},
}
SEQUENCE_MEMBERS = {
    'snapshots',
    'distinctSnapshots',
    'snapshotPublisher',
    'pendingCompletionUpdates',
    'SnapshotSequence',
    'SnapshotWaitResult',
}
# Protocol declarations whose requirements name a confined host's types without constructing a task or a host.
DECLARATION_REFERENCES = {'StateMachineHosting.swift'}


def assert_shared_fixture_scope():
    """The excluded hosts are linked definitions, never instantiated by this workload."""
    fixture = Path(__file__).resolve().parent
    if '@StateMachine(mode: .shared)' not in (fixture / 'Domain.swift').read_text():
        raise ValueError('Resource exclusion requires the Shared benchmark domain')
    for name in ['Main.swift', 'Support.swift', 'Workloads.swift']:
        tokens = [token for token, _, _ in swift_tokens((fixture / name).read_text())]
        if CONFINED_TYPES.intersection(tokens):
            raise ValueError('Benchmark now references an excluded confined host: ' + name)
        if SEQUENCE_MEMBERS.intersection(tokens):
            raise ValueError('Benchmark now registers an excluded snapshot sequence or publisher: ' + name)
        for index in range(len(tokens) - 2):
            if tokens[index:index + 2] == ['PerformanceFlow', '.'] and tokens[index + 2] in {'Actor', 'MainActor'}:
                raise ValueError('Benchmark now references a confined facade: ' + name)

HOST = '''
extension RuntimeSharedHost {
    public func performanceResourceCounts() async -> [String: Int] {
        let state = storage.load().value
        var counts = state.engine.performanceResourceCounts
        counts["subscribers"] = state.subscribers.count
        counts["pendingDeliveries"] = state.ledger.pendingCount
        counts["coordinatorWorkers"] = await coordinator?.runningCount ?? 0
        counts["progressWaiters"] = await progress.performanceWaiterCount
        counts["trackedTaskHandles"] = RuntimeCoordinatorTaskProbe.trackedCount
        counts["pendingMailboxes"] = state.subscribers.reduce(0) { $0 + $1.mailbox.performanceResourceCounts[0] }
        counts["scheduledMailboxes"] = state.subscribers.reduce(0) { $0 + $1.mailbox.performanceResourceCounts[1] }
        return counts
    }
    public func performanceWeakMarkers(subscribersOnly: Bool = false) -> [RuntimeHostWeakProbe] {
        let state = storage.load().value
        var markers: [RuntimeHostWeakProbe] = []
        if !subscribersOnly {
            markers = [RuntimeHostWeakProbe(storage), RuntimeHostWeakProbe(progress)]
            if let coordinator { markers.append(RuntimeHostWeakProbe(coordinator)) }
        }
        for subscriber in state.subscribers { markers += subscriber.mailbox.performanceWeakMarkers() }
        return markers
    }
}
'''
ENGINE = '''
extension RuntimeState {
    public var performanceResourceCounts: [String: Int] {
        ["activeAuthority": active.count, "executionReservations": reservations.count,
         "preparationClaims": reservations.filter { $0.claim != nil }.count,
         "queuedOrdinaryBatches": queue.count, "queuedTerminalBatches": terminal == nil ? 0 : 1]
    }
}
'''
MAILBOX = '''
extension LatestMailbox {
    var performanceResourceCounts: [Int] {
        storage.withLock { [$0.pending == nil ? 0 : 1, $0.scheduled ? 1 : 0] }
    }
    func performanceWeakMarkers() -> [RuntimeHostWeakProbe] {
        [RuntimeHostWeakProbe(self)]
    }
}
'''


# Record preparation counts for each scheduling turn and reset between cohorts.
DELIVERY = '''
public enum RuntimeDeliveryProbe {
    private static let storage = AtomicRecordStorage<[Int]>([])
    public static var rounds: [Int] { storage.load().value }
    public static func record(_ preparations: Int) {
        while true {
            let before = storage.load()
            if storage.install(.init(before.value + [preparations]), replacing: before) { return }
        }
    }
    public static func reset() {
        while true {
            let before = storage.load()
            if storage.install(.init([]), replacing: before) { return }
        }
    }
}
'''


def copy_resources(command, destination):
    destination.mkdir(parents=True, exist_ok=False)
    directory = destination / 'Sources'
    directory.mkdir()
    observations, outputs, patches, inventory = [], [], [], []
    assert_shared_fixture_scope()
    for original in map(Path, command['sources']):
        text = original.read_text()
        original_hash = hashlib.sha256(text.encode()).hexdigest()
        sites = task_constructions(text)
        disposition = 'no task constructions'
        if original.name in {'RuntimeDeliveryLedger.swift', 'RuntimeState.swift'} and sites:
            raise ValueError('Unexpected task construction in metadata-only resource patch: ' + original.name)
        amended = text
        if original.name == 'RuntimeCoordinator.swift':
            if len(sites) != 2 or any(site['kind'] != 'Task.detached' or site['generic'] for site in sites):
                raise ValueError('Coordinator worker/watcher constructor inventory drift')
            for site, binding in zip(sites, ['let worker = ', 'let watcher = ']):
                line = text[text.rfind('\n', 0, site['start']) + 1:site['start']].strip()
                if line != binding.strip(): raise ValueError('Coordinator task role drift')
            disposition = 'Outcome worker joined by exact watcher, with Void watcher registered at assignment'
            needle = '            entries[index].watcher = watcher'
            if text.count(needle) != 1: raise ValueError('Coordinator watcher patch drift')
            amended = text.replace(needle, needle + '\n            RuntimeCoordinatorTaskProbe.keep(watcher)') + REGISTRY
            patches.append({'file': original.name, 'watcherAssignments': 1,
                            'registry': 'Retain task handles in an atomically replaced registry, then drain and await each cohort until empty.'})
        elif original.name == 'RuntimeSharedHost.swift':
            disposition = 'all Void constructions registered and joined'
            amended = track(text, 10)
            needle = '        var waiters: [(RuntimeIdentity, CheckedContinuation<Void, Never>)] = []'
            if amended.count(needle) != 1: raise ValueError('Progress waiter patch drift')
            amended = amended.replace(needle, needle + '\n        var performanceWaiterCount: Int { waiters.count }') + HOST
            patches.append({'file': original.name, 'trackedVoidTaskSites': 10, 'progressWaiterGetter': 1})
        elif original.name == 'LatestMailbox.swift':
            disposition = 'all Void constructions registered and joined'
            amended = track(text, 4) + MAILBOX
            patches.append({'file': original.name, 'trackedVoidTaskSites': 4})
        elif original.name == 'RuntimeDeliveryLedger.swift':
            needle = '        var preparations = 0'
            if text.count(needle) != 1: raise ValueError('Ledger preparation-round patch drift')
            amended = text.replace(needle, needle + '\n        defer { RuntimeDeliveryProbe.record(preparations) }') + DELIVERY
            patches.append({'file': original.name, 'preparationRoundDefers': 1})
        elif original.name == 'RuntimeState.swift':
            for needle in ['private var reservations: [Reservation] = []', 'private var queue = RuntimeFIFO<Batch>()', 'private var terminal: Batch?']:
                if text.count(needle) != 1: raise ValueError('Engine sample patch drift: ' + needle)
            amended = text + ENGINE
            patches.append({'file': original.name, 'assertedPrivateEngineFields': 3})
        elif original.name in SEQUENCE_EXCLUSIONS:
            actual = {}
            for site in sites:
                if site['generic']: raise ValueError('Sequence generic Task spelling changed. Review exclusion')
                actual[site['kind']] = actual.get(site['kind'], 0) + 1
            if actual != SEQUENCE_EXCLUSIONS[original.name]:
                raise ValueError('Excluded sequence Task inventory drift: ' + original.name + ' ' + str(actual))
            disposition = 'explicitly excluded sequence and publisher tasks because the benchmark registers callbacks only'
            patches.append({'file': original.name, 'excludedTaskSites': len(sites), 'constructorKinds': actual,
                            'reason': disposition})
        elif original.name in CONFINED_EXCLUSIONS:
            actual = {}
            for site in sites:
                if site['generic']: raise ValueError('Confined generic Task spelling changed. Review exclusion')
                actual[site['kind']] = actual.get(site['kind'], 0) + 1
            if actual != CONFINED_EXCLUSIONS[original.name]:
                raise ValueError('Excluded confined-host Task inventory drift: ' + original.name + ' ' + str(actual))
            disposition = 'explicitly excluded unused confined host because the Shared/Local benchmark never instantiates it'
            patches.append({'file': original.name, 'excludedTaskSites': len(sites), 'constructorKinds': actual,
                            'reason': disposition})
        elif sites:
            raise ValueError('Uncovered library task construction in ' + original.name)
        if original.name not in set(CONFINED_EXCLUSIONS) | set(SEQUENCE_EXCLUSIONS) | DECLARATION_REFERENCES and CONFINED_TYPES.intersection(token for token, _, _ in swift_tokens(text)):
            raise ValueError('Exercised source now references an excluded confined host: ' + original.name)
        inventory.append({'file': original.name, 'source_sha256': original_hash, 'sites': sites, 'disposition': disposition})
        output = directory / original.name
        output.write_text(amended)
        observations.append({'original': str(original), 'original_sha256': original_hash, 'copy': str(output),
                             'copy_sha256': digest(output), 'instrumented': text != amended})
        if digest(original) != original_hash: raise ValueError('Source changed during resource copy: ' + str(original))
        outputs.append(output)
    required = {'RuntimeCoordinator.swift', 'RuntimeSharedHost.swift', 'LatestMailbox.swift', 'RuntimeDeliveryLedger.swift', 'RuntimeState.swift'} | set(CONFINED_EXCLUSIONS) | set(SEQUENCE_EXCLUSIONS)
    if {p['file'] for p in patches} != required:
        raise ValueError('Missing required task patch scope')
    (destination / 'task-inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    (destination / 'source-copy.json').write_text(json.dumps(observations, indent=2) + '\n')
    (destination / 'asserted-patches.json').write_text(json.dumps(patches, indent=2) + '\n')
    return outputs
