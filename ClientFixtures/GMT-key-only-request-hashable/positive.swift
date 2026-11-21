// A request that carries only a key is Hashable, as every key is.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Files: Sendable {
    struct Browsing: Sendable {}
    struct Note: Sendable {}
    @Initial case browsing(Browsing)
    enum Input: Sendable { case open(Int), annotate(Int) }
    @Operation(activeIn: [Browsing.self])
    enum Download { typealias Key = Int }
    @Operation(activeIn: [Browsing.self])
    enum Annotate { typealias Key = Int; typealias Input = Note }
    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id)])
    }
    @Transition(on: Input.annotate, starts: [Annotate.self])
    fileprivate static func annotate(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Annotate> {
        Change(source, effects: [.annotate(key: id, input: Note())])
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(_ source: Browsing, request: DownloadRequest) -> Browsing { source }
    @Transition(onSuccess: Annotate.self)
    fileprivate static func annotated(_ source: Browsing, request: AnnotateRequest) -> Browsing { source }
}

let downloads: Set<Files.DownloadRequest> = [Files.DownloadRequest(key: 1)]
