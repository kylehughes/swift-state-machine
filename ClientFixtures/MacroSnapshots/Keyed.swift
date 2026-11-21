import StateMachine

/// Keyed work, cancellation by key, and completions that read the request their work started with.
@StateMachine(mode: .shared)
nonisolated public enum Library: Sendable {
    public struct Browsing: Sendable {
        let titles: [Int: String]
        public init(titles: [Int: String] = [:]) { self.titles = titles }
    }
    public struct Archived: Sendable {}
    @Initial case browsing(Browsing = Browsing())
    @Terminal case archived(Archived)
    public enum Problem: Error, Sendable { case missing }
    public enum Input: Sendable { case open(Int), close(Int), closeAll, refresh, archive }
    @Operation(activeIn: [Browsing.self], admission: .latest)
    public enum Download {
        public typealias Key = Int
        public typealias Input = String
        public typealias Output = String
        public typealias Failure = Problem
    }
    @Operation(activeIn: [Browsing.self], admission: .rejectWhenActive)
    public enum Index {
        public typealias Key = Int
    }
    @Operation(activeIn: [Browsing.self])
    public enum Refresh {}
    @Transition(on: Input.open, starts: [Download.self, Index.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "title-\(id)"), .index(key: id)])
    }
    @Transition(on: Input.close, cancels: [Download.self])
    fileprivate static func close(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Close> {
        Change(source, effects: [.cancelDownload(key: id)])
    }
    @Transition(on: Input.closeAll, cancels: [Download.self])
    fileprivate static func closeAll(_ source: Browsing) -> Change<Browsing, Effect.CloseAll> {
        Change(source, effects: [.cancelAllDownload])
    }
    @Transition(on: Input.refresh, starts: [Refresh.self])
    fileprivate static func refresh(_ source: Browsing) -> Change<Browsing, Effect.Refresh> {
        Change(source, effects: [.refresh])
    }
    @Transition(on: Input.archive)
    fileprivate static func archive(_ source: Browsing) -> Archived { Archived() }
    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(_ source: Browsing, _ title: String, request: DownloadRequest) -> Browsing {
        var titles = source.titles
        titles[request.key] = title
        return Browsing(titles: titles)
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func ignored(_ source: Browsing, _ title: String) -> Browsing { source }
    @Route(onSuccess: Download.self)
    fileprivate static func file(_ source: Browsing, _ title: String, request: DownloadRequest) -> Route.File {
        request.input.isEmpty ? .ignored : .downloaded
    }
    @Transition(onFailure: Download.self)
    fileprivate static func missed(_ source: Browsing, _ problem: Problem, request: DownloadRequest) -> Browsing {
        var titles = source.titles
        titles[request.key] = nil
        return Browsing(titles: titles)
    }
    @Transition(onSuccess: Index.self)
    fileprivate static func indexed(_ source: Browsing) -> Browsing { source }
    @Transition(onSuccess: Refresh.self)
    fileprivate static func refreshed(_ source: Browsing) -> Browsing { source }
}
