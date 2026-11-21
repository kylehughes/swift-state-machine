import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// An `Owned` routed method takes its payload with an ownership chosen from the router's and its edges'
/// spellings alone, so the method is legal whatever type the payload is, a nonescaping closure or a
/// noncopyable value among them, whenever the router and its edges are.
struct RoutedOwnershipTests {
    /// A router and two edges taking `PAYLOAD` as `ROUTER`, `KEEP`, and `LOOK` spell it.
    private static let bay = #"""
        @StateMachine(mode: .isolated, owners: [.owned])
        nonisolated enum Bay {
            typealias Work = @Sendable () -> Swift::Int
            nonisolated struct Empty {}
            nonisolated struct Kept {}
            nonisolated struct Seen {}
            @Initial case empty(Empty)
            @Terminal case kept(Kept)
            @Terminal case seen(Seen)
            enum Input: Swift::Sendable { case offer(PAYLOAD) }
            @Route(on: Input.offer)
            fileprivate static func choose(_ source: Empty, _ work: ROUTERPAYLOAD) -> Route.Choose { .keep }
            @Transition(on: Input.offer)
            fileprivate static func keep(_ source: Empty, _ work: KEEPPAYLOAD) -> Kept { Kept() }
            @Transition(on: Input.offer)
            fileprivate static func look(_ source: Empty, _ work: LOOKPAYLOAD) -> Seen { Seen() }
        }
        """#

    private static func expansion(payload: String, router: String, keep: String, look: String) throws -> String {
        let source = Self.bay.replacingOccurrences(of: "ROUTER", with: router)
            .replacingOccurrences(of: "KEEP", with: keep).replacingOccurrences(of: "LOOK", with: look)
            .replacingOccurrences(of: "PAYLOAD", with: payload)
        let schema = try DeclarationHygieneTests.parse(source)
        return try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
    }

    /// The routed method's parameter, and whether it checks the payload is copyable, for each group of
    /// spellings: escaping, with no ownership or `__shared` with `sending`, when some function takes the
    /// payload `@escaping`; plain when some function declares no ownership, or the router takes the
    /// payload as its own; otherwise the ownership that passes it on, `consuming` only where a function of
    /// the group spells it; and otherwise a lending one.
    @Test(arguments: [
        // The reported group: a router that takes the closure `sending`, one edge that borrows it, and
        // one that takes it plain; Swift rejects `consuming` on a nonescaping closure.
        ("sending ", "borrowing ", "", "sending @Sendable () -> Swift::Int", false),
        ("", "", "", "@Sendable () -> Swift::Int", false),
        ("borrowing ", "borrowing ", "borrowing ", "borrowing @Sendable () -> Swift::Int", false),
        // An edge that takes it `__owned`, which a nonescaping closure allows and `consuming` does not.
        ("borrowing ", "__owned ", "borrowing ", "__owned @Sendable () -> Swift::Int", false),
        ("__shared ", "__owned sending ", "__shared ", "__owned sending @Sendable () -> Swift::Int", false),
        // `__shared sending` lends the payload, and is the one lending spelling `sending` can join.
        ("__shared sending ", "borrowing ", "borrowing ", "__shared sending @Sendable () -> Swift::Int", false),
        // `@escaping` shows the payload is a function, which is copyable, so the method takes it escaping
        // and lends it to every function, escaping or not.
        (
            "borrowing @escaping ", "consuming @escaping ", "borrowing @escaping ",
            "@escaping @Sendable () -> Swift::Int", false
        ),
        ("borrowing ", "borrowing ", "borrowing @escaping ", "@escaping @Sendable () -> Swift::Int", false),
        (
            "__shared ", "", "consuming sending @escaping ",
            "__shared sending @escaping @Sendable () -> Swift::Int", false
        ),
        // A router that owns the payload while an edge takes it after needs a copyable payload, which every
        // function declaring an ownership leaves to the check.
        ("__owned ", "borrowing ", "borrowing ", "@Sendable () -> Swift::Int", true),
        ("__owned ", "", "borrowing ", "@Sendable () -> Swift::Int", false),
    ])
    func aRoutedMethodFollowsTheGroupsSpellings(
        router: String,
        keep: String,
        look: String,
        parameter: String,
        checksCopy: Bool
    ) throws {
        for payload in ["@Sendable () -> Swift::Int", "Work"] {
            let text = try Self.expansion(payload: payload, router: router, keep: keep, look: look)
            let spelled = parameter.replacingOccurrences(of: "@Sendable () -> Swift::Int", with: payload)
            #expect(text.contains("func choose(_ input: \(spelled)) -> Route.ChooseResult"), "\(payload) \(parameter)")
            // The router is handed the payload itself, which a plain parameter copies where it must.
            #expect(text.contains("_StateMachineSchema.choose(phase, input)"))
            #expect(text.contains("_stateMachineCopy(") == checksCopy)
            #expect(!text.contains("copy input"))
        }
    }

    /// A payload that every function takes with an ownership, which may be noncopyable, is checked by its
    /// type when the router consumes it while an edge takes it after, which a closure need not give up to
    /// reach a generic parameter; an edge that consumes it instead makes the method consume it.
    @Test func aCopyCheckNamesThePayloadsType() throws {
        let text = try Self.expansion(
            payload: "Swift::Int",
            router: "consuming ",
            keep: "borrowing ",
            look: "borrowing "
        )
        #expect(text.contains("func choose(_ input: Swift::Int) -> Route.ChooseResult"))
        #expect(
            text.contains(
                "_StateMachineSchema._stateMachineCopy(_StateMachineSchema._TriggerPayloadMatchesDeclaration<Swift::Int>())"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineCopy<Value>(_ payload: _TriggerPayloadMatchesDeclaration<Value>) {}"
            )
        )
        let consuming = try Self.expansion(
            payload: "Swift::Int",
            router: "borrowing ",
            keep: "consuming ",
            look: "borrowing "
        )
        #expect(consuming.contains("func choose(_ input: consuming Swift::Int) -> Route.ChooseResult"))
        #expect(!consuming.contains("_stateMachineCopy"))
    }

    /// A direct verb repeats the authored parameter's spelling, `__owned` and `__shared sending` among them,
    /// so it is legal whenever the authored function is.
    @Test func aDirectVerbRepeatsTheAuthoredSpelling() throws {
        let text = try Self.expansion(
            payload: "@Sendable () -> Swift::Int",
            router: "__shared sending ",
            keep: "__owned ",
            look: "__shared sending "
        )
        #expect(text.contains("func keep(_ input: __owned @Sendable () -> Swift::Int)"))
        #expect(text.contains("func look(_ input: __shared sending @Sendable () -> Swift::Int)"))
        #expect(!text.contains("borrowing sending"))
    }
}
