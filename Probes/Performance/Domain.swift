import StateMachine

/// Payload byte count excludes Array storage metadata, this header, and facade metadata.
@StateMachine(mode: .shared)
nonisolated enum PerformanceFlow: Sendable {
    struct Ready: Sendable {
        var bytes: [UInt8]
        var changes: UInt64 = 0
        var completions: UInt64 = 0
    }
    @Initial case ready(Ready)
    enum Scope { case work }
    enum Input: Sendable {
        case bump(UInt64)
        case start(Int)
        case cancel
    }
    @Operation(scope: Scope.work, activeIn: [Ready.self], admission: .parallel(limit: 16))
    enum Work {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Transition(on: Input.bump)
    fileprivate static func bump(_ source: Ready, _ salt: UInt64) -> Ready {
        var next = source
        // The historical source still owns its Array, so this write exercises CoW.
        let index = Int(salt % UInt64(next.bytes.count))
        next.bytes[index] &+= 1
        next.changes += 1
        return next
    }
    @Transition(on: Input.start, starts: [Work.self])
    fileprivate static func start(_ source: Ready, _ id: Int) -> Change<Ready, Effect.Start> {
        var next = source
        next.bytes[id % next.bytes.count] &+= 1
        next.changes += 1
        return Change(next, effects: [.work(id)])
    }
    @Transition(on: Input.cancel, invalidates: [Scope.work])
    fileprivate static func cancel(_ source: Ready) -> Ready { source }
    @Transition(onSuccess: Work.self)
    fileprivate static func completed(_ source: Ready, _ id: Work.Output) -> Ready {
        var next = source
        next.completions += 1
        return next
    }
}

#if PERFORMANCE_RESOURCE_INSTRUMENTED
extension PerformanceFlow.Shared {
    func performanceResourceCounts() async -> [String: Int] { await host.performanceResourceCounts() }
    func performanceWeakMarkers(subscribersOnly: Bool = false) -> [RuntimeHostWeakProbe] {
        host.performanceWeakMarkers(subscribersOnly: subscribersOnly)
    }
}
#endif
