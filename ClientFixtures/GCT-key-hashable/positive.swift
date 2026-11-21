// A key is Hashable and Sendable, so admission can resolve it outside every lock.
import StateMachine

nonisolated struct Token: Hashable, Sendable { let id: Int }

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
        typealias Key = Token
        typealias Input = String
        typealias Output = String
    }
    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: Token(id: id), input: "file-\(id)")])
    }
    @Transition(on: Input.remove, cancels: [Download.self])
    fileprivate static func remove(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Remove> {
        Change(source, effects: [.cancelDownload(key: Token(id: id))])
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func opened(_ source: Browsing, _ output: Download.Output, request: DownloadRequest) -> Browsing {
        source
    }
}
