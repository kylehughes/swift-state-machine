/// Elements in the order they arrived, from which a matcher takes the oldest, or the oldest that is
/// still live, in constant amortized work.
///
/// A matched element is not removed where it stands: the caller's liveness test rejects it, and the
/// queue drops it once its head reaches it. The queue drops the part before its head once that part is
/// at least half of the storage, and a scan of every element compacts the ones it found ended, so a
/// backlog consumed oldest first costs work linear in its length.
nonisolated struct ArrivalQueue<Element: Sendable>: Sendable {
    private var elements: [Element] = []
    private var head = 0
    /// How many elements the queue has examined, which tests read as the work of matching.
    private(set) var examined = 0

    var isEmpty: Bool { head == elements.count }

    mutating func append(_ element: Element) { elements.append(element) }

    /// The oldest element, without examining whether it is live.
    var first: Element? { head < elements.count ? elements[head] : nil }

    /// Removes the oldest element.
    mutating func removeFirst() {
        head += 1
        dropTaken()
    }

    /// The oldest element that `isLive` accepts, after dropping the ended elements before it.
    mutating func oldest(where isLive: (Element) -> Bool) -> Element? {
        while head < elements.count {
            examined += 1
            if isLive(elements[head]) { return elements[head] }
            head += 1
        }
        dropTaken()
        return nil
    }

    /// The live elements from the oldest, in order, through the first that `last` accepts.
    ///
    /// A scan that reaches the end compacts the queue to the live elements it found.
    mutating func live(where isLive: (Element) -> Bool, through last: (Element) -> Bool = { _ in false }) -> [Element] {
        var found: [Element] = []
        var index = head
        while index < elements.count {
            examined += 1
            let element = elements[index]
            index += 1
            guard isLive(element) else { continue }
            found.append(element)
            if last(element) { return found }
        }
        elements = found
        head = 0
        return found
    }

    private mutating func dropTaken() {
        guard head > 0, head * 2 >= elements.count else { return }
        elements.removeFirst(head)
        head = 0
    }
}
