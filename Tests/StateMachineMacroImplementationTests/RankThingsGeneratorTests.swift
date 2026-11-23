import SwiftParser
import SwiftSyntax
import Testing

@testable import StateMachineMacros

/// Code generation and shielding for routed handoffs (`routed:`) and generic multi-source transitions (`<Source>`).
struct RankThingsGeneratorTests {
    private static func parse(_ text: String) throws -> Schema {
        let syntax = Parser.parse(source: text)
        guard
            let declaration = syntax.statements.compactMap({ $0.item.as(EnumDeclSyntax.self) })
                .first(where: { $0.attributes.contains { $0.trimmedDescription.hasPrefix("@StateMachine") } }),
            let attribute = declaration.attributes.first?.as(AttributeSyntax.self)
        else { fatalError("Malformed test fixture") }
        return try Schema.parse(declaration, attribute: attribute)
    }

    private static func expand(_ text: String) throws -> String {
        let schema = try parse(text)
        return try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
    }

    // MARK: - Feature 1: routed: handoff

    @Test func plainRouterPreservesConformancesAndSchemaAccess() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum Flow {
                public struct Idle: Sendable {}
                public struct Done: Sendable {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                public enum Input: Sendable { case go }

                @Transition(on: Input.go)
                fileprivate static func left(_ source: Idle) -> Done { Done() }
                @Transition(on: Input.go)
                fileprivate static func right(_ source: Idle) -> Idle { source }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: Idle) -> Route.Choose { .left }
            }
            """#
        )
        #expect(
            text.contains(
                "public enum Choose: Swift::Sendable, Swift::Equatable, Swift::Hashable, Swift::CaseIterable"
            )
        )
        #expect(text.contains("public typealias Choose = Flow.Route.Choose"))
        #expect(text.contains("switch selection {"))
        #expect(!text.contains("switch consume selection"))
    }

    @Test func routedInputRouterNarrowsAccessAndPreservesPublicSignatures() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public enum Flow {
                public struct Pending { public let raw: Int }
                public struct Browsing { public let id: Int? }
                public struct Presenting { public let id: Int?; public let sheet: String }
                @Initial case pending(Pending)
                @Terminal case browsing(Browsing)
                @Terminal case presenting(Presenting)
                public enum Input { case resolve(Set<Int>) }

                fileprivate struct Target {
                    let id: Int?
                    let callback: () -> String
                }

                @Transition(on: Input.resolve)
                fileprivate static func resolveToBrowsing(
                    _ source: Pending,
                    _ available: Set<Int>,
                    routed selectedID: Int?
                ) -> Browsing {
                    Browsing(id: selectedID)
                }

                @Transition(on: Input.resolve)
                fileprivate static func resolveToSheet(
                    _ source: Pending,
                    _ available: Set<Int>,
                    routed target: (selectedID: Int?, sheet: String)
                ) -> Presenting {
                    Presenting(id: target.selectedID, sheet: target.sheet)
                }

                @Transition(on: Input.resolve)
                fileprivate static func resolveFallback(
                    _ source: Pending,
                    _ available: Set<Int>
                ) -> Browsing {
                    Browsing(id: nil)
                }

                @Transition(on: Input.resolve)
                fileprivate static func resolveSecret(
                    _ source: Pending,
                    _ available: Set<Int>,
                    routed secret: Target
                ) -> Presenting {
                    Presenting(id: secret.id, sheet: secret.callback())
                }

                @Route(on: Input.resolve)
                fileprivate static func routeResolve(
                    _ source: Pending,
                    _ available: Set<Int>
                ) -> Route.RouteResolve {
                    .resolveFallback
                }
            }
            """#
        )
        // Choice enum and phase alias are fileprivate (no leakage in public schema) and omit value conformances.
        #expect(text.contains("fileprivate enum RouteResolve {"))
        #expect(text.contains("fileprivate typealias RouteResolve = Flow.Route.RouteResolve"))
        #expect(!text.contains("public enum RouteResolve {"))
        #expect(!text.contains("public typealias RouteResolve ="))
        #expect(text.contains("case resolveToBrowsing(Int?)"))
        #expect(text.contains("case resolveToSheet((selectedID: Int?, sheet: String))"))
        #expect(text.contains("case resolveFallback\n"))
        #expect(text.contains("case resolveSecret(Flow.Target)"))

        // Public Owned and Observed router signatures stay unchanged.
        #expect(
            text.contains(
                "public consuming func routeResolve(_ input: Set<Int>) -> Route.RouteResolveResult where Phase == Pending"
            )
        )
        #expect(text.contains("public func routeResolve(_ input: Set<Int>) -> Prepared where Phase == Pending"))

        // Candidate methods stay fileprivate and carry `routed:`.
        #expect(
            text.contains(
                "fileprivate consuming func resolveToSheet(_ input: Set<Int>, routed: (selectedID: Int?, sheet: String)) -> Owned<Presenting> where Phase == Pending"
            )
        )
        #expect(
            text.contains(
                "fileprivate func resolveToSheet(_ input: Set<Int>, routed: (selectedID: Int?, sheet: String)) -> Prepared where Phase == Pending"
            )
        )
        #expect(
            text.contains(
                "_StateMachineSchema.resolveToSheet(phase, input, routed: routed)"
            )
        )
        #expect(
            text.contains(
                "_StateMachineSchema.resolveToSheet(payload, input, routed: routed)"
            )
        )

        // Dispatch binds routed payload and leaves empty alternatives bare.
        #expect(
            text.contains(
                "case .resolveToSheet(let routed): return .resolveToSheet(self.resolveToSheet(input, routed: routed))"
            )
        )
        #expect(text.contains("case .resolveFallback: return .resolveFallback(self.resolveFallback(input))"))
        #expect(text.contains("case .resolveToSheet(let routed): return source.resolveToSheet(input, routed: routed)"))
        #expect(text.contains("case .resolveFallback: return source.resolveFallback(input)"))
    }

    @Test func completionRouterOrdersPayloadRequestRoutedAndAuthority() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum Flow {
                public struct Loading: Sendable {}
                public struct Done: Sendable {}
                @Initial case loading(Loading)
                @Terminal case done(Done)

                @Operation(activeIn: [Loading.self])
                public enum Fetch {
                    public typealias Input = Int
                    public typealias Output = String
                }

                public enum Input: Sendable { case start }

                @Transition(on: Input.start, starts: [Fetch.self])
                fileprivate static func start(_ source: Loading) -> Change<Loading, Effect.Start> {
                    Change(source, effects: [.fetch(1)])
                }

                @Transition(onSuccess: Fetch.self)
                fileprivate static func finishWithData(
                    _ source: Loading,
                    _ output: String,
                    request: FetchRequest,
                    routed parsed: Int
                ) -> Done {
                    Done()
                }

                @Transition(onSuccess: Fetch.self)
                fileprivate static func retryLoading(
                    _ source: Loading,
                    _ output: String,
                    request: FetchRequest
                ) -> Loading {
                    source
                }

                @Route(onSuccess: Fetch.self)
                fileprivate static func routeFetch(
                    _ source: Loading,
                    _ output: String,
                    request: FetchRequest
                ) -> Route.RouteFetch {
                    .retryLoading
                }
            }
            """#
        )
        // Observed candidate method keeps authority last after payload, request, and routed.
        #expect(
            text.contains(
                "fileprivate func finishWithData(_ value: Fetch.Output, request: FetchRequest, routed: Int, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Loading"
            )
        )
        // _stateMachineCompletion passes value, request, routed, authority in order.
        #expect(
            text.contains(
                "case .finishWithData(let routed): return source.finishWithData(value, request: completion.request, routed: routed, authority: completion.authority)"
            )
        )
        #expect(
            text.contains(
                "case .retryLoading: return source.retryLoading(value, request: completion.request, authority: completion.authority)"
            )
        )
        // Owned candidate and router preserve payload, request, routed ordering.
        #expect(
            text.contains(
                "fileprivate consuming func finishWithData(_ input: String, request: FetchRequest, routed: Int) -> Owned<Done> where Phase == Loading"
            )
        )
        #expect(
            text.contains(
                "case .finishWithData(let routed): return .finishWithData(self.finishWithData(input, request: request, routed: routed))"
            )
        )
        #expect(
            text.contains(
                "_StateMachineSchema.finishWithData(payload, value, request: request, routed: routed)"
            )
        )
    }

    @Test func noncopyableAndOwnershipRoutedChoicesUseConsumeSwitch() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public enum Flow {
                public struct Handle: ~Copyable { public let fd: Int }
                public struct Open { public let id: Int }
                public struct Taken { public let fd: Int }
                public struct Closed {}
                @Initial case open(Open)
                @Terminal case taken(Taken)
                @Terminal case closed(Closed)
                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func take(_ source: Open, routed handle: consuming Handle) -> Taken {
                    Taken(fd: handle.fd)
                }

                @Transition(on: Input.go)
                fileprivate static func inspect(_ source: Open, routed handle: borrowing Handle) -> Closed {
                    _ = handle.fd
                    return Closed()
                }

                @Transition(on: Input.go)
                fileprivate static func abort(_ source: Open) -> Closed {
                    Closed()
                }

                @Route(on: Input.go)
                fileprivate static func routeOpen(_ source: Open) -> Route.RouteOpen {
                    .abort
                }
            }
            """#
        )
        #expect(text.contains("fileprivate enum RouteOpen: ~Swift::Copyable {"))
        #expect(text.contains("case take(Flow.Handle)"))
        #expect(text.contains("case inspect(Flow.Handle)"))
        #expect(text.contains("case abort"))
        // Owned, Observed, and prepare all switch with `switch consume selection`.
        #expect(text.components(separatedBy: "switch consume selection {").count == 4)
        #expect(
            text.contains(
                "fileprivate consuming func take(routed: consuming Handle) -> Owned<Taken> where Phase == Open"
            )
        )
        #expect(
            text.contains(
                "fileprivate consuming func inspect(routed: borrowing Handle) -> Owned<Closed> where Phase == Open"
            )
        )
        #expect(
            text.contains(
                "fileprivate func take(routed: consuming Handle) -> Prepared where Phase == Open"
            )
        )
        #expect(
            text.contains(
                "fileprivate func inspect(routed: borrowing Handle) -> Prepared where Phase == Open"
            )
        )
    }

    @Test func functionAndSendingConventionsStripFromEnumCaseAndStayOnCandidateMethods() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public enum Flow {
                public struct Ready {}
                public struct Done {}
                @Initial case ready(Ready)
                @Terminal case done(Done)
                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func withEscaping(_ source: Ready, routed work: @escaping () -> Int) -> Done {
                    _ = work()
                    return Done()
                }

                @Transition(on: Input.go)
                fileprivate static func withSending(_ source: Ready, routed token: sending Int) -> Done {
                    _ = token
                    return Done()
                }

                @Route(on: Input.go)
                fileprivate static func choose(_ source: Ready) -> Route.Choose {
                    .withSending(1)
                }
            }
            """#
        )
        #expect(text.contains("fileprivate enum Choose {"))
        #expect(!text.contains("fileprivate enum Choose: ~Swift::Copyable"))
        #expect(text.contains("case withEscaping(() -> Int)"))
        #expect(text.contains("case withSending(Int)"))
        #expect(
            text.contains(
                "fileprivate consuming func withEscaping(routed: @escaping () -> Int) -> Owned<Done> where Phase == Ready"
            )
        )
        #expect(
            text.contains(
                "fileprivate func withSending(routed: sending Int) -> Prepared where Phase == Ready"
            )
        )
    }

    @Test func duplicateRouterNamesShareOnlyCompatibleRoutedLayoutsAndAccess() throws {
        // Compatible access + compatible routed payloads -> shared Route.Choose.
        let compatible = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum SharedChoiceFlow {
                public struct A: Sendable {}
                public struct B: Sendable {}
                public struct Done: Sendable {}
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case go }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: A, routed step: Int) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: A) -> Done { Done() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: A) -> Route.Choose { .stop }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: B, routed step: Int) -> A { A() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: B) -> Done { Done() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: B) -> Route.Choose { .stop }
            }
            """#
        )
        #expect(compatible.contains("fileprivate enum Choose {"))
        #expect(compatible.contains("fileprivate typealias Choose = SharedChoiceFlow.Route.Choose"))

        // Different access (fileprivate vs public) -> not shared; separate per-phase enums with distinct access.
        let differentAccess = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum SplitAccessFlow {
                public struct A: Sendable {}
                public struct B: Sendable {}
                public struct Done: Sendable {}
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case go }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: A, routed step: Int) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: A) -> Done { Done() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: A) -> Route.A.Choose { .stop }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: B, routed step: Int) -> A { A() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: B) -> Done { Done() }
                @Route(on: Input.go)
                public static func choose(_ source: B) -> Route.B.Choose { .stop }
            }
            """#
        )
        #expect(!differentAccess.contains("typealias Choose = SplitAccessFlow.Route.Choose"))
        #expect(differentAccess.contains("fileprivate enum Choose {"))
        #expect(differentAccess.contains("public enum Choose {"))

        // Different routed payload types -> not shared.
        let differentPayload = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum SplitPayloadFlow {
                public struct A: Sendable {}
                public struct B: Sendable {}
                public struct Done: Sendable {}
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case go }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: A, routed step: Int) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: A) -> Done { Done() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: A) -> Route.A.Choose { .stop }

                @Transition(on: Input.go)
                fileprivate static func next(_ source: B, routed step: String) -> A { A() }
                @Transition(on: Input.go)
                fileprivate static func stop(_ source: B) -> Done { Done() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: B) -> Route.B.Choose { .stop }
            }
            """#
        )
        #expect(!differentPayload.contains("typealias Choose = SplitPayloadFlow.Route.Choose"))
        #expect(differentPayload.contains("case next(Int)"))
        #expect(differentPayload.contains("case next(String)"))
    }

    @Test func spellingShieldKeepsFileprivateAliasForShadowedFileprivateRoutedType() throws {
        let text = try Self.expand(
            #"""
            fileprivate struct Outer {}

            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public enum Flow {
                public struct Ready {}
                public struct Done {}
                @Initial case ready(Ready)
                @Terminal case done(Done)
                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func finish(_ source: Ready, routed value: Outer) -> Done { Done() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: Ready) -> Ready { source }

                @Route(on: Input.go)
                fileprivate static func outer(_ source: Ready) -> Route.Outer { .stay }
            }
            """#
        )
        // Outer is shadowed by Route.Outer inside Route, so SpellingShield keeps a schema-level alias,
        // and because Route.Outer is fileprivate, the alias must stay fileprivate (never public).
        #expect(text.contains("fileprivate typealias _StateMachineType1 = Outer"))
        #expect(!text.contains("public typealias _StateMachineType1"))
        #expect(text.contains("case finish(_StateMachineType1)"))
    }

    // MARK: - Feature 2: Generic <Source> on @Transition(from:)

    @Test func genericFromGeneratesConcretePerPhaseCallsWitnessesAndDeprecations() throws {
        let text = try Self.expand(
            #"""
            protocol SelectionCarrying {
                var selectedID: Int? { get set }
            }

            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum NavFlow {
                public struct Browsing: Sendable, SelectionCarrying { public var selectedID: Int? }
                public struct Confirming: Sendable, SelectionCarrying {
                    public var selectedID: Int?
                    public let reason: String
                }
                public struct Presenting: Sendable, SelectionCarrying {
                    public var selectedID: Int?
                    public let sheet: String
                }
                @Initial case browsing(Browsing)
                case confirming(Confirming)
                case presenting(Presenting)

                @PhaseSet([Browsing.self, Confirming.self, Presenting.self])
                fileprivate enum AllPhases {}

                public enum Input: Sendable {
                    case select(Int?)
                    case presentSheet(String)
                    case confirm(String)
                }

                @available(*, deprecated, message: "use select")
                @Transition(from: AllPhases.self, on: Input.select)
                fileprivate static func select<Source: SelectionCarrying>(
                    _ source: Source,
                    _ id: Int?
                ) -> Source {
                    var next = source
                    next.selectedID = id
                    return next
                }

                @Transition(from: [Browsing.self, Confirming.self], on: Input.presentSheet)
                fileprivate static func presentSheet<Source: SelectionCarrying>(
                    _ source: Source,
                    _ sheet: String
                ) -> Presenting {
                    Presenting(selectedID: source.selectedID, sheet: sheet)
                }

                @Transition(on: Input.confirm)
                fileprivate static func confirm(_ source: Browsing, _ reason: String) -> Confirming {
                    Confirming(selectedID: source.selectedID, reason: reason)
                }
            }
            """#
        )
        // Bound forwarding helpers preserve each declaration's generic constraints without leaking Source into Owned/Observed.
        #expect(!text.contains("<Source>"))
        #expect(
            text.contains(
                "@available(*, deprecated)\nfileprivate static func _stateMachineGeneric8<Source: SelectionCarrying>(_ _source: Source, _ _payload: Int?) -> Source"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric9<Source: SelectionCarrying>(_ _source: Source, _ _payload: String) -> _StateMachineSchema.Presenting"
            )
        )
        #expect(!text.contains("-> Owned<Source>"))
        #expect(!text.contains("where Phase == Source"))

        // Concrete per-phase Owned & Observed methods for same-phase `-> Source`.
        #expect(text.contains("public consuming func select(_ input: Int?) -> Owned<Browsing> where Phase == Browsing"))
        #expect(
            text.contains("public consuming func select(_ input: Int?) -> Owned<Confirming> where Phase == Confirming")
        )
        #expect(
            text.contains("public consuming func select(_ input: Int?) -> Owned<Presenting> where Phase == Presenting")
        )

        // Concrete per-phase witnesses for EVERY expanded phase (first, middle, last).
        #expect(
            text.contains(
                "let _: _TransitionSourceIsPhasePayload<Browsing> = _TransitionSourceIsPhasePayload<Browsing>()"
            )
        )
        #expect(
            text.contains(
                "let _: _TransitionSourceIsPhasePayload<Confirming> = _TransitionSourceIsPhasePayload<Confirming>()"
            )
        )
        #expect(
            text.contains(
                "let _: _TransitionSourceIsPhasePayload<Presenting> = _TransitionSourceIsPhasePayload<Presenting>()"
            )
        )
        #expect(
            text.contains(
                "let _: _TransitionReturnsDeclaredResult<Browsing> = _TransitionReturnsDeclaredResult<Browsing>()"
            )
        )
        #expect(
            text.contains(
                "let _: _TransitionReturnsDeclaredResult<Confirming> = _TransitionReturnsDeclaredResult<Confirming>()"
            )
        )
        #expect(
            text.contains(
                "let _: _TransitionReturnsDeclaredResult<Presenting> = _TransitionReturnsDeclaredResult<Presenting>()"
            )
        )

        // Concrete per-phase deprecation protocol requirements & calls.
        #expect(
            text.contains("static func select(_ argument0: NavFlow.Browsing, _ argument1: Int?) -> NavFlow.Browsing")
        )
        #expect(
            text.contains(
                "static func select(_ argument0: NavFlow.Confirming, _ argument1: Int?) -> NavFlow.Confirming"
            )
        )
        #expect(
            text.contains(
                "static func select(_ argument0: NavFlow.Presenting, _ argument1: Int?) -> NavFlow.Presenting"
            )
        )
        #expect(text.contains("_StateMachineSchema._stateMachineDeprecated.select(phase, input)"))

        // Graph records each concrete expanded self-loop and fixed-destination edge.
        #expect(text.contains(#"id: "browsing.select", name: "select""#))
        #expect(text.contains(#"source: "browsing", destination: "browsing""#))
        #expect(text.contains(#"id: "confirming.select", name: "select""#))
        #expect(text.contains(#"source: "confirming", destination: "confirming""#))
        #expect(text.contains(#"id: "presenting.select", name: "select""#))
        #expect(text.contains(#"source: "presenting", destination: "presenting""#))
        #expect(text.contains(#"id: "browsing.presentSheet", name: "presentSheet""#))
        #expect(text.contains(#"id: "confirming.presentSheet", name: "presentSheet""#))
    }

    @Test func genericFromSupportsChangeEffectsAndOwnedOnlyAdvance() throws {
        let changeText = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum EditFlow {
                public struct Browsing: Sendable {}
                public struct Reordering: Sendable {}
                @Initial case browsing(Browsing)
                case reordering(Reordering)

                @Event public enum Deleted { public typealias Payload = Int }
                public enum Input: Sendable { case toggle, delete(Int) }

                @Transition(on: Input.toggle)
                fileprivate static func startReordering(_ source: Browsing) -> Reordering { Reordering() }
                @Transition(on: Input.toggle)
                fileprivate static func stopReordering(_ source: Reordering) -> Browsing { Browsing() }

                @Transition(from: [Browsing.self, Reordering.self], on: Input.delete, emits: [Deleted.self])
                fileprivate static func deleteImmediately<Source>(
                    _ source: Source,
                    _ id: Int
                ) -> Change<Source, Effect.DeleteImmediately> {
                    Change(source, effects: [.deleted(id)])
                }
            }
            """#
        )
        #expect(
            changeText.contains(
                "public consuming func deleteImmediately(_ input: Int) -> StateMachine::Change<Owned<Browsing>, Effect.DeleteImmediately> where Phase == Browsing"
            )
        )
        #expect(
            changeText.contains(
                "public consuming func deleteImmediately(_ input: Int) -> StateMachine::Change<Owned<Reordering>, Effect.DeleteImmediately> where Phase == Reordering"
            )
        )
        #expect(
            changeText.contains(
                "fileprivate static func _stateMachineGeneric8<Source>(_ _source: Source, _ _payload: Int) -> StateMachine::Change<Source, _StateMachineSchema.Effect.DeleteImmediately>"
            )
        )
        #expect(
            changeText.contains(
                "let change: StateMachine::Change<Browsing, Effect.DeleteImmediately> = _StateMachineSchema._stateMachineGeneric8(phase, input)"
            )
        )
        #expect(
            changeText.contains(
                "let change: StateMachine::Change<Reordering, Effect.DeleteImmediately> = _StateMachineSchema._stateMachineGeneric8(phase, input)"
            )
        )
        #expect(
            changeText.contains(
                "let change: StateMachine::Change<Browsing, Effect.DeleteImmediately> = _StateMachineSchema._stateMachineGeneric8(payload, input)"
            )
        )
        #expect(
            changeText.contains(
                "let change: StateMachine::Change<Reordering, Effect.DeleteImmediately> = _StateMachineSchema._stateMachineGeneric8(payload, input)"
            )
        )

        let advanceText = try Self.expand(
            #"""
            protocol Titled: ~Copyable {
                var title: String { get set }
            }

            @StateMachine(mode: .ownedOnly)
            public enum DocFlow: ~Copyable {
                public struct Draft: ~Copyable, Titled { public var title: String }
                public struct Review: ~Copyable, Titled { public var title: String }
                public struct Published: ~Copyable {}
                public enum RenameFailure: Error { case empty }
                @Initial case draft(Draft)
                case review(Review)
                @Terminal case published(Published)
                public enum Input { case submit, publish, rename(String) }

                @Transition(on: Input.submit)
                fileprivate static func submit(_ source: consuming Draft) -> Review { Review(title: source.title) }
                @Transition(on: Input.publish)
                fileprivate static func publish(_ source: consuming Review) -> Published { Published() }

                @Transition(from: [Draft.self, Review.self], on: Input.rename)
                fileprivate static func rename<Source: Titled & ~Copyable>(
                    _ source: consuming Source,
                    _ title: String
                ) -> Advance<Source, Source, Never, RenameFailure> {
                    guard !title.isEmpty else { return .rejected(.empty, source) }
                    var next = source
                    next.title = title
                    return .advanced(next, effects: [])
                }
            }
            """#
        )
        #expect(
            advanceText.contains(
                "public consuming func rename(_ input: String) -> StateMachine::Advance<Self, Owned<Draft>, Swift::Never, RenameFailure> where Phase == Draft"
            )
        )
        #expect(
            advanceText.contains(
                "public consuming func rename(_ input: String) -> StateMachine::Advance<Self, Owned<Review>, Swift::Never, RenameFailure> where Phase == Review"
            )
        )
        #expect(
            advanceText.contains(
                "let _: _TransitionReturnsDeclaredResult<StateMachine::Advance<Draft, Draft, Swift::Never, RenameFailure>> = _TransitionReturnsDeclaredResult<Advance<Draft, Draft, Never, RenameFailure>>()"
            )
        )
        #expect(
            advanceText.contains(
                "let _: _TransitionReturnsDeclaredResult<StateMachine::Advance<Review, Review, Swift::Never, RenameFailure>> = _TransitionReturnsDeclaredResult<Advance<Review, Review, Never, RenameFailure>>()"
            )
        )
    }

    @Test func genericFromComposesWithRoutedHandoff() throws {
        let text = try Self.expand(
            #"""
            protocol Tagged { var tag: Int { get } }

            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum ComposedFlow {
                public struct A: Sendable, Tagged { public let tag: Int }
                public struct B: Sendable, Tagged { public let tag: Int }
                public struct Done: Sendable { public let total: Int }
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case step, next }

                @Transition(on: Input.next)
                fileprivate static func toB(_ source: A) -> B { B(tag: source.tag) }

                @Transition(from: [A.self, B.self], on: Input.step)
                fileprivate static func finish<Source: Tagged>(
                    _ source: Source,
                    routed delta: Int
                ) -> Done {
                    Done(total: source.tag + delta)
                }

                @Transition(from: [A.self, B.self], on: Input.step)
                fileprivate static func keep<Source: Tagged>(_ source: Source) -> Source {
                    source
                }

                @Route(on: Input.step)
                fileprivate static func routeStep(_ source: A) -> Route.RouteStep { .finish(1) }

                @Route(on: Input.step)
                fileprivate static func routeStep(_ source: B) -> Route.RouteStep { .keep }
            }
            """#
        )
        // Both phases share Route.RouteStep and forward routed: to their concrete fileprivate finish methods.
        #expect(text.contains("fileprivate enum RouteStep {"))
        #expect(text.contains("case finish(Int)"))
        #expect(
            text.contains(
                "fileprivate consuming func finish(routed: Int) -> Owned<Done> where Phase == A"
            )
        )
        #expect(
            text.contains(
                "fileprivate consuming func finish(routed: Int) -> Owned<Done> where Phase == B"
            )
        )
        #expect(
            text.contains(
                "fileprivate func finish(routed: Int) -> Prepared where Phase == A"
            )
        )
        #expect(
            text.contains(
                "fileprivate func finish(routed: Int) -> Prepared where Phase == B"
            )
        )
        #expect(text.contains("case .finish(let routed): return source.finish(routed: routed)"))
    }

    @Test func genericFromOverloadsEmitDistinctBoundForwardingHelpers() throws {
        let text = try Self.expand(
            #"""
            protocol BaseP { var tag: Int { get } }
            protocol RefinedQ: BaseP { var detail: String { get } }

            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum RefinedFlow {
                public struct A: Sendable, RefinedQ { public let tag: Int; public let detail: String }
                public struct B: Sendable, RefinedQ { public let tag: Int; public let detail: String }
                public struct Done: Sendable { public let label: String }
                @Event public enum Ping { public typealias Payload = String }
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case toB, finish(Int), finishWithEvent(Int), samePhase, shadow }

                @Transition(on: Input.toB)
                fileprivate static func toB(_ source: A) -> B { B(tag: source.tag, detail: source.detail) }

                @Transition(from: [A.self], on: Input.finish)
                fileprivate static func finish<Source: BaseP>(_ source: Source, _ code: Int) -> Done {
                    Done(label: "P:\(source.tag):\(code)")
                }

                @Transition(from: [B.self], on: Input.finish)
                fileprivate static func finish<Source: RefinedQ>(_ source: Source, _ code: Int) -> Done {
                    Done(label: "Q:\(source.detail):\(code)")
                }

                @Transition(from: [A.self], on: Input.finishWithEvent, emits: [Ping.self])
                fileprivate static func finishWithEvent<Source: BaseP>(
                    _ source: Source,
                    _ code: Int
                ) -> Change<Done, Effect.FinishWithEvent> {
                    Change(Done(label: "P:\(code)"), effects: [.ping("P")])
                }

                @Transition(from: [B.self], on: Input.finishWithEvent, emits: [Ping.self])
                fileprivate static func finishWithEvent<Source: RefinedQ>(
                    _ source: Source,
                    _ code: Int
                ) -> Change<Done, Effect.FinishWithEvent> {
                    Change(Done(label: "Q:\(code)"), effects: [.ping("Q")])
                }

                @Transition(from: [A.self], on: Input.samePhase)
                fileprivate static func samePhase<Source>(_ source: Source) -> Source where Source: BaseP {
                    source
                }

                @Transition(from: [B.self], on: Input.samePhase)
                fileprivate static func samePhase<Source>(_ source: Source) -> Source where Source: RefinedQ {
                    source
                }

                @Transition(from: [A.self, B.self], on: Input.shadow)
                fileprivate static func shadow<Done: BaseP>(_ source: Done) -> Self.Done {
                    Done(label: "\(source.tag)")
                }
            }
            """#
        )
        // Distinct helpers bind each overload to its own generic parameter and where clauses.
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric9<Source: BaseP>(_ _source: Source, _ _payload: Int) -> _StateMachineSchema.Done"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric10<Source: RefinedQ>(_ _source: Source, _ _payload: Int) -> _StateMachineSchema.Done"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric11<Source: BaseP>(_ _source: Source, _ _payload: Int) -> StateMachine::Change<_StateMachineSchema.Done, _StateMachineSchema.Effect.FinishWithEvent>"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric12<Source: RefinedQ>(_ _source: Source, _ _payload: Int) -> StateMachine::Change<_StateMachineSchema.Done, _StateMachineSchema.Effect.FinishWithEvent>"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric13<Source>(_ _source: Source) -> Source where Source: BaseP"
            )
        )
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric14<Source>(_ _source: Source) -> Source where Source: RefinedQ"
            )
        )
        // Generic parameter named `Done` does not capture the fixed destination phase type.
        #expect(
            text.contains(
                "fileprivate static func _stateMachineGeneric15<Done: BaseP>(_ _source: Done) -> _StateMachineSchema.Done"
            )
        )
        // Owned and Observed route A and B to their respective declaration helpers.
        #expect(text.contains("Owned<Done>(_StateMachineSchema._stateMachineGeneric9(phase, input))"))
        #expect(text.contains("Owned<Done>(_StateMachineSchema._stateMachineGeneric10(phase, input))"))
        #expect(text.contains("let next: Done = _StateMachineSchema._stateMachineGeneric9(payload, input)"))
        #expect(text.contains("let next: Done = _StateMachineSchema._stateMachineGeneric10(payload, input)"))
        #expect(
            text.contains(
                "let change: StateMachine::Change<Done, Effect.FinishWithEvent> = _StateMachineSchema._stateMachineGeneric11(phase, input)"
            )
        )
        #expect(
            text.contains(
                "let change: StateMachine::Change<Done, Effect.FinishWithEvent> = _StateMachineSchema._stateMachineGeneric12(phase, input)"
            )
        )
    }

    @Test func genericFromOverloadsHandleOwnedAdvanceAndDeprecations() throws {
        let advanceText = try Self.expand(
            #"""
            protocol PA: ~Copyable { var a: Int { get } }
            protocol PB: ~Copyable { var b: Int { get } }

            @StateMachine(mode: .ownedOnly)
            public enum AdvanceOverloadFlow: ~Copyable {
                public struct P1: ~Copyable, PA, PB { public var a: Int; public var b: Int }
                public struct P2: ~Copyable, PA, PB { public var a: Int; public var b: Int }
                public struct D1: ~Copyable {}
                public struct D2: ~Copyable {}
                public enum Fail: Error { case bad }
                @Initial case p1(P1)
                case p2(P2)
                @Terminal case d1(D1)
                @Terminal case d2(D2)
                public enum Input { case toP2, go }

                @Transition(on: Input.toP2)
                fileprivate static func toP2(_ source: consuming P1) -> P2 { P2(a: source.a, b: source.b) }

                @Transition(from: [P1.self], on: Input.go)
                fileprivate static func go<Source: PA & ~Copyable>(
                    _ source: consuming Source
                ) -> Advance<Source, D1, Never, Fail> {
                    .advanced(D1(), effects: [])
                }

                @Transition(from: [P2.self], on: Input.go)
                fileprivate static func go<Source: PB & ~Copyable>(
                    _ source: consuming Source
                ) -> Advance<Source, D2, Never, Fail> {
                    .advanced(D2(), effects: [])
                }
            }
            """#
        )
        #expect(
            advanceText.contains(
                "fileprivate static func _stateMachineGeneric11<Source: PA & ~Copyable>(_ _source: consuming Source) -> StateMachine::Advance<Source, _StateMachineSchema.D1, Swift::Never, Fail>"
            )
        )
        #expect(
            advanceText.contains(
                "fileprivate static func _stateMachineGeneric12<Source: PB & ~Copyable>(_ _source: consuming Source) -> StateMachine::Advance<Source, _StateMachineSchema.D2, Swift::Never, Fail>"
            )
        )
        #expect(
            advanceText.contains(
                "let advance: StateMachine::Advance<P1, D1, Swift::Never, Fail> = _StateMachineSchema._stateMachineGeneric11(phase)"
            )
        )
        #expect(
            advanceText.contains(
                "let advance: StateMachine::Advance<P2, D2, Swift::Never, Fail> = _StateMachineSchema._stateMachineGeneric12(phase)"
            )
        )

        let deprecatedText = try Self.expand(
            #"""
            protocol BaseP { var tag: Int { get } }
            protocol RefinedQ: BaseP { var detail: String { get } }

            @StateMachine(mode: .shared, owners: [.owned, .local])
            public enum DeprecatedOverloadFlow {
                public struct A: Sendable, RefinedQ { public let tag: Int; public let detail: String }
                public struct B: Sendable, RefinedQ { public let tag: Int; public let detail: String }
                public struct Done: Sendable { public let label: String }
                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)
                public enum Input: Sendable { case toB, finish(Int) }

                @Transition(on: Input.toB)
                fileprivate static func toB(_ source: A) -> B { B(tag: source.tag, detail: source.detail) }

                @available(*, deprecated, message: "old P")
                @Transition(from: [A.self], on: Input.finish)
                fileprivate static func finish<Source: BaseP>(_ source: Source, _ code: Int) -> Done {
                    Done(label: "P:\(source.tag):\(code)")
                }

                @available(*, deprecated, message: "old Q")
                @Transition(from: [B.self], on: Input.finish)
                fileprivate static func finish<Source: RefinedQ>(_ source: Source, _ code: Int) -> Done {
                    Done(label: "Q:\(source.detail):\(code)")
                }
            }
            """#
        )
        #expect(
            deprecatedText.contains(
                "@available(*, deprecated)\nfileprivate static func _stateMachineGeneric8<Source: BaseP>(_ _source: Source, _ _payload: Int) -> _StateMachineSchema.Done"
            )
        )
        #expect(
            deprecatedText.contains(
                "@available(*, deprecated)\nfileprivate static func _stateMachineGeneric9<Source: RefinedQ>(_ _source: Source, _ _payload: Int) -> _StateMachineSchema.Done"
            )
        )
        #expect(deprecatedText.contains("_StateMachineSchema._stateMachineGeneric8(argument0, argument1)"))
        #expect(deprecatedText.contains("_StateMachineSchema._stateMachineGeneric9(argument0, argument1)"))
    }

    @Test func overloadedParameterlessFromAnnotatesOwnedChange() throws {
        let text = try Self.expand(
            #"""
            @StateMachine(mode: .shared, owners: [.owned])
            public enum ParameterlessOverloadFlow {
                public struct A: Sendable {}
                public struct B: Sendable {}
                public struct D1: Sendable {}
                public struct D2: Sendable {}
                @Event public enum Logged { public typealias Payload = String }
                @Initial case a(A)
                case b(B)
                @Terminal case d1(D1)
                @Terminal case d2(D2)
                public enum Input: Sendable { case toB, go }

                @Transition(on: Input.toB)
                fileprivate static func toB(_ source: A) -> B { B() }

                @Transition(from: [A.self], on: Input.go, emits: [Logged.self])
                fileprivate static func go() -> Change<D1, Effect.Go> {
                    Change(D1(), effects: [.logged("A")])
                }

                @Transition(from: [B.self], on: Input.go, emits: [Logged.self])
                fileprivate static func go() -> Change<D2, Effect.Go> {
                    Change(D2(), effects: [.logged("B")])
                }
            }
            """#
        )
        #expect(
            text.contains(
                "let change: StateMachine::Change<D1, Effect.Go> = _StateMachineSchema.go()"
            )
        )
        #expect(
            text.contains(
                "let change: StateMachine::Change<D2, Effect.Go> = _StateMachineSchema.go()"
            )
        )
    }
}
