// A schema whose completion edge can refuse an outcome names its completion policy; one that cannot
// defaults to retrying.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Screening: Sendable {
    struct Ready: Sendable {}
    @Initial case ready(Ready)
    enum Input: Sendable { case check(Int) }
    enum Refusal: Error, Sendable { case negative }
    @Operation(activeIn: [Ready.self])
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }
    @Transition(on: Input.check, starts: [Check.self])
    fileprivate static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return source
    }
}
@StateMachine(mode: .shared)
nonisolated enum Files: Sendable {
    struct Browsing: Sendable {}
    @Initial case browsing(Browsing)
    enum Input: Sendable {
        case open(Int)
        case remove(Int)
    }
    @Operation(activeIn: [Browsing.self])
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
    }
    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "file-\(id)")])
    }
    @Transition(on: Input.remove, cancels: [Download.self])
    fileprivate static func remove(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Remove> {
        Change(source, effects: [.cancelDownload(key: id)])
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func opened(_ source: Browsing, _ output: Download.Output, request: DownloadRequest) -> Browsing {
        source
    }
}

nonisolated func screening() -> Screening.Shared { Screening.Shared(Screening.Ready(), checkDriver: { $0 }, completionPolicy: .manual) }
nonisolated func files() -> Files.Shared { Files.Shared(Files.Browsing(), downloadDriver: { _, input in input }) }
@MainActor func main() -> Screening.MainActorHost {
    Screening.MainActorHost(Screening.Ready(), checkDriver: { $0 }, completionPolicy: .retry)
}
