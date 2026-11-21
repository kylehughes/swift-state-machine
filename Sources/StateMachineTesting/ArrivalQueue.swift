/// Elements in the order they arrived, from which a matcher takes the oldest, or the oldest that is
/// still live, in constant amortized work.
///
/// A matched element is not removed where it stands: the caller's liveness test rejects it, and the
/// queue drops it once its head reaches it. An element that the liveness test once rejects stays
/// ended. Every scan advances the head past the ended elements it passed, and a scan that stops early
/// keeps only the live elements it passed, so no later scan passes the same ended element again. The
/// queue drops the part before its head once that part is at least half of the storage, on every exit,
/// so waits matched first or calls matched first, and long traffic that alternates between them, cost
/// work linear in the elements matched and storage linear in the elements still live. Elements that end
/// without any scan reaching them, as waits cancelled before a call starts, are dropped by `reclaim(keeping:where:)`
/// once they outnumber the live ones.
nonisolated struct ArrivalQueue<Element: Sendable>: Sendable {
    private var elements: [Element] = []
    private var head = 0
    /// How many elements the queue has examined, which tests read as the work of matching.
    ///
    /// It saturates instead of overflowing.
    private(set) var examined = 0 { didSet { if examined < oldValue { examined = .max } } }

    var isEmpty: Bool { head == elements.count }
    /// How many elements the queue stores, ended ones before the head included, which tests read as
    /// its storage.
    var storedCount: Int { elements.count }

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
        defer { dropTaken() }
        while head < elements.count {
            examined &+= 1
            if isLive(elements[head]) { return elements[head] }
            head += 1
        }
        return nil
    }

    /// The live elements from the oldest, in order, through the first that `last` accepts.
    ///
    /// A scan that reaches the end compacts the queue to the live elements it found.
    mutating func live(where isLive: (Element) -> Bool, through last: (Element) -> Bool = { _ in false }) -> [Element] {
        var found: [Element] = []
        var index = head
        while index < elements.count {
            examined &+= 1
            let element = elements[index]
            index += 1
            guard isLive(element) else { continue }
            found.append(element)
            guard last(element) else { continue }
            // The live elements passed move up against the rest, in order, and the head follows them,
            // so the ended ones they passed fall before the head.
            head = index - found.count
            for (offset, live) in found.enumerated() { elements[head + offset] = live }
            dropTaken()
            return found
        }
        elements = found
        head = 0
        return found
    }

    /// Keeps only the elements that `isLive` accepts once the stored elements reach twice `live`, the
    /// number still live, and 16 more, so elements that end unmatched keep storage, and the work of
    /// dropping them, proportional to the elements still live.
    mutating func reclaim(keeping live: Int, where isLive: (Element) -> Bool) {
        guard elements.count >= 2 * live + 16 else { return }
        examined &+= elements.count - head
        elements = elements[head...].filter(isLive)
        head = 0
    }

    private mutating func dropTaken() {
        guard head > 0, head * 2 >= elements.count else { return }
        elements.removeFirst(head)
        head = 0
    }
}
