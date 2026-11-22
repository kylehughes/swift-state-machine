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
    /// The oldest queued element, without taking it.
    package var first: Element? { head < slots.count ? slots[head] : nil }
    /// How many elements reclaiming taken slots has moved, which tests read as the queue's work.
    ///
    /// It saturates instead of overflowing.
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
            let (sum, overflow) = moved.addingReportingOverflow(slots.count - head)
            moved = overflow ? .max : sum
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
/// delivers them through one delivery at a time, from the oldest. A delivery takes every report queued
/// so far at once and keeps delivering until it finds the queue empty, so a `Shared` owner detaches its
/// backlog in one installation instead of copying it for each report. A call that queues a report while
/// a delivery is in progress, from inside a handler that delivery runs or, on a `Shared` owner, from
/// another thread, leaves its report to that delivery, which delivers it after every report queued
/// before it. No report is therefore ever delivered before one queued earlier.
nonisolated package struct RuntimeReportQueue<Report> {
    private var reports = RuntimeFIFO<Report>()
    /// Whether a delivery has taken a report and not yet found the queue empty.
    package private(set) var isDelivering = false

    /// Creates an empty queue.
    package init() {}

    /// Queues `report` after every report already queued.
    package mutating func append(_ report: Report) { reports.append(report) }

    /// Takes every queued report, oldest first, for a delivery to make in that order.
    ///
    /// A call that is not `continuing` a delivery begins one only when none is in progress. Otherwise
    /// it takes nothing, and the delivery in progress delivers what it would have. A delivery that
    /// finds the queue empty ends.
    package mutating func takeAll(continuing: Bool) -> RuntimeFIFO<Report>? {
        if !continuing, isDelivering { return nil }
        guard !reports.isEmpty else {
            isDelivering = false
            return nil
        }
        isDelivering = true
        return exchange(&reports, with: RuntimeFIFO())
    }
}

extension RuntimeReportQueue: Sendable where Report: Sendable {}
