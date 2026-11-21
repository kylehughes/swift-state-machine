/// A first-in, first-out queue whose removal from the front takes amortized constant time.
///
/// Taking an element releases the queue's reference to it at once. The slots of taken elements are
/// reclaimed once they make up half of the storage, so the storage stays proportional to the elements
/// still queued.
nonisolated package struct RuntimeFIFO<Element> {
    private var slots: [Element?] = []
    private var head = 0

    /// Creates an empty queue.
    package init() {}

    /// Whether no element is queued.
    package var isEmpty: Bool { head == slots.count }
    /// The number of queued elements.
    package var count: Int { slots.count - head }
    /// The number of slots the queue stores, taken ones included, for a test of its reclamation.
    package var storedCount: Int { slots.count }
    /// How many elements reclaiming taken slots has moved, which tests read as the queue's work.
    package private(set) var moved = 0

    /// Queues `element` after every element already queued.
    package mutating func append(_ element: Element) { slots.append(element) }

    /// Takes the oldest queued element, or returns `nil` when none is queued.
    package mutating func popFirst() -> Element? {
        guard head < slots.count else { return nil }
        let element = slots[head].take()
        head += 1
        if head == slots.count {
            slots.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 16, head * 2 >= slots.count {
            moved += slots.count - head
            slots.removeFirst(head)
            head = 0
        }
        return element
    }
}

extension RuntimeFIFO: Sendable where Element: Sendable {}

/// The reports an owner has decided to make and not yet made, in the order it decided them, and
/// whether a delivery of them is in progress.
///
/// An owner queues each report in the same change that makes its decision, before any callout, and
/// delivers them through one delivery at a time, from the oldest. A call that queues a report while a
/// delivery is in progress, from inside a handler that delivery runs or, on a `Shared` owner, from
/// another thread, leaves its report to that delivery, which delivers it after every report queued
/// before it. No report is therefore ever delivered before one queued earlier.
nonisolated package struct RuntimeReportQueue<Report> {
    private var reports = RuntimeFIFO<Report>()
    /// Whether a delivery has taken a report and not yet found the queue empty.
    package private(set) var isDelivering = false

    /// Creates an empty queue.
    package init() {}

    /// Whether no report is queued.
    package var isEmpty: Bool { reports.isEmpty }

    /// Queues `report` after every report already queued.
    package mutating func append(_ report: Report) { reports.append(report) }

    /// Takes the next report for a delivery.
    ///
    /// A call that is not `continuing` a delivery begins one only when none is in progress; otherwise
    /// it takes nothing, and the delivery in progress delivers what it would have. A delivery that
    /// finds the queue empty ends.
    package mutating func take(continuing: Bool) -> Report? {
        if !continuing, isDelivering { return nil }
        guard let report = reports.popFirst() else {
            isDelivering = false
            return nil
        }
        isDelivering = true
        return report
    }
}

extension RuntimeReportQueue: Sendable where Report: Sendable {}
