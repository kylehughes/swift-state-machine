// An edge that only starts an operation cannot cancel its work.
import StateMachine

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
        Change(source, effects: [.cancelDownload(key: id)])
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
