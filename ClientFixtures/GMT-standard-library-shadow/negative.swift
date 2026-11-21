// An authored spelling keeps its lexical meaning: beside the schema's own `Swift`, `Swift.String`
// names a member of that type, which it does not declare.
import StateMachine

struct Actor {}
struct Array {}
struct Bool {}
struct CaseIterable {}
struct ContinuousClock {}
struct Copyable {}
struct CustomStringConvertible {}
struct Equatable {}
struct Error {}
struct Hashable {}
struct Int {}
struct MainActor {}
struct Never {}
struct Result {}
struct Sendable {}
struct String {}
struct UInt32 {}
struct UInt64 {}
struct Void {}

@StateMachine(mode: .shared)
nonisolated enum Library: Swift::Sendable, Swift::Hashable {
    struct Actor {}
    struct Array {}
    struct Bool {}
    struct CaseIterable {}
    struct ContinuousClock {}
    struct Copyable {}
    struct CustomStringConvertible {}
    struct Equatable {}
    struct Error {}
    struct Hashable {}
    struct Int {}
    struct MainActor {}
    struct Never {}
    struct Result {}
    struct Sendable {}
    struct String {}
    struct UInt32 {}
    struct UInt64 {}
    struct Void {}
    static func preconditionFailure(_ message: Swift::String) {}
    enum Swift {}
    struct Browsing: Swift::Sendable, Swift::Hashable { var count: Swift::Int = 0 }
    struct Archived: Swift::Sendable, Swift::Hashable {}
    @Initial case browsing(Browsing = Browsing())
    @Terminal case archived(Archived)
    enum Problem: Swift::Error, Swift::Hashable { case missing }
    enum Input: Swift::Sendable { case open(Swift::Int), close(Swift::Int), refresh, archive }
    @Operation(activeIn: [Browsing.self], admission: .parallel(limit: 2))
    enum Download {
        typealias Key = Swift::Int
        typealias Output = Swift.String
        typealias Failure = Problem
    }
    @Operation(activeIn: [Browsing.self])
    enum Refresh {}
    @Event
    enum Logged { typealias Payload = Swift::String }
    @Restoration(allows: [Browsing.self])
    fileprivate static func restore(_ saved: Swift::Int) throws(Problem) -> Restoration {
        guard saved >= 0 else { throw .missing }
        return .browsing(Browsing(count: saved))
    }
    @Transition(on: Input.open, starts: [Download.self], emits: [Logged.self])
    fileprivate static func open(_ source: Browsing, _ id: Swift::Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.logged("open"), .download(key: id)])
    }
    @Transition(on: Input.close, cancels: [Download.self])
    fileprivate static func close(_ source: Browsing, _ id: Swift::Int) -> Change<Browsing, Effect.Close> {
        Change(source, effects: [.cancelDownload(key: id)])
    }
    @Transition(on: Input.refresh, starts: [Refresh.self])
    fileprivate static func refresh(_ source: Browsing) -> Change<Browsing, Effect.Refresh> {
        Change(source, effects: [.refresh])
    }
    @Transition(on: Input.archive)
    fileprivate static func archive(_ source: Browsing) -> Archived { Archived() }
    @Transition(on: Input.archive)
    fileprivate static func keep(_ source: Browsing) throws(Problem) -> Browsing { source }
    @Route(on: Input.archive)
    fileprivate static func decide(_ source: Browsing) throws(Problem) -> Route.Decide {
        source.count > 0 ? .archive : .keep
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(_ source: Browsing, _ title: Swift::String) -> Browsing {
        Browsing(count: source.count + 1)
    }
    @Transition(onFailure: Download.self)
    fileprivate static func missed(_ source: Browsing, _ problem: Problem) -> Browsing { source }
    @Transition(onSuccess: Refresh.self)
    fileprivate static func refreshed(_ source: Browsing) -> Browsing { source }
}

final class Box { var text = "" }

@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Actor {}
    struct Bool {}
    struct Copyable {}
    struct Error {}
    struct Int {}
    struct MainActor {}
    struct Never {}
    struct Result {}
    struct Sendable {}
    struct String {}
    struct UInt64 {}
    struct Void {}
    struct Draft { let box: Box }
    struct Saving { let box: Box }
    @Initial case draft(Draft)
    case saving(Saving)
    enum Input { case save, edit(Swift::String) }
    @Operation(activeIn: [Saving.self], admission: .rejectWhenActive)
    enum Save {
        typealias Input = Box
        typealias Output = Box
    }
    @Operation(activeIn: [Draft.self])
    enum Autosave { typealias Input = Swift::String }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Draft) -> Change<Saving, Effect.Save> {
        Change(Saving(box: source.box), effects: [.save(source.box)])
    }
    @Transition(on: Input.edit, starts: [Autosave.self])
    fileprivate static func edit(_ source: Draft, _ text: Swift::String) -> Change<Draft, Effect.Edit> {
        Change(source, effects: [.autosave(text)])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving, _ box: Save.Output) -> Draft { Draft(box: box) }
    @Transition(onSuccess: Autosave.self)
    fileprivate static func autosaved(_ source: Draft) -> Draft { source }
}

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueCounter: ~Swift::Copyable {
    struct Copyable {}
    struct Never {}
    struct Error {}
    struct Bool {}
    struct Idle: ~Swift::Copyable { var value: Swift::Int = 0 }
    struct Done: ~Swift::Copyable { let value: Swift::Int }
    @Initial case idle(Idle = Idle())
    @Terminal case done(Done)
    enum Input { case finish(Swift::Bool) }
    enum Rejection: Swift::Error { case declined }
    @Transition(on: Input.finish)
    fileprivate static func finish(
        _ source: consuming Idle,
        _ accept: Swift::Bool
    ) -> Advance<Idle, Done, Swift::Never, Rejection> {
        if accept { return .advanced(Done(value: source.value), effects: []) }
        return .rejected(.declined, source)
    }
}

@Swift::MainActor func use(_ library: Library.MainActorHost, _ note: borrowing Note.Local) throws {
    try library.send(.open(1))
    _ = library.snapshot()
    _ = note.snapshot()
}
