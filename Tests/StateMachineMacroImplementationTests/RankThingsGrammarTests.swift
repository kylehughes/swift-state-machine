import SwiftDiagnostics
import Testing

@testable import StateMachineMacros

/// Parser model, visibility, choice-sharing, and diagnostic-anchor coverage for `routed:` handoffs
/// and generic `<Source>` multi-source `@Transition(from:)` declarations.
struct RankThingsGrammarTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    // MARK: - Feature 1: `routed:` handoff

    @Test func routedInputAndMixedCandidatesParseAndPreserveGraphEdges() throws {
        let source = #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
            enum RankingFlow {
                struct Step { let done: Bool }
                struct Comparing {}
                struct Reviewing {}

                @Initial case comparing(Comparing)
                @Terminal case reviewing(Reviewing)

                enum Input { case choose(Bool) }

                @Transition(on: Input.choose)
                fileprivate static func advance(_ source: Comparing, _ side: Bool, routed next: Step?) -> Comparing {
                    Comparing()
                }

                @Transition(on: Input.choose)
                fileprivate static func finish(
                    _ source: Comparing,
                    _ side: Bool,
                    routed result: (next: Step, count: Int)
                ) -> Reviewing {
                    Reviewing()
                }

                @Route(on: Input.choose)
                fileprivate static func routeChoice(_ source: Comparing, _ side: Bool) -> Route.RouteChoice {
                    .advance(nil)
                }
            }
            """#
        let schema = try Self.parse(source)
        let route = try #require(schema.routes.first)
        #expect(schema.hasRoutedPayload(route))
        #expect(schema.choiceAccess(route) == .fileprivate)
        #expect(!schema.choiceIsNoncopyable(route))
        #expect(schema.sharesChoice(route.name))

        let branches = schema.branches(route)
        #expect(branches.map(\.name) == ["advance", "finish"])
        #expect(branches[0].routedType == "Step?")
        #expect(branches[1].routedType == "(next: Step, count: Int)")
        #expect(schema.graphFindings().isEmpty)
    }

    @Test func routedVoidOutputCompletionKeepsProducesVoidAndSupportsRequestBeforeRouted() throws {
        let source = #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
            enum Demo {
                fileprivate struct Step { let resolve: () -> Int }
                struct Ready {}
                struct Comparing {}
                struct Finished {}

                @Initial case ready(Ready)
                case comparing(Comparing)
                @Terminal case finished(Finished)

                enum Input { case start }

                @Operation(activeIn: [Ready.self, Comparing.self])
                enum StepDelay { typealias Input = Int }

                @Transition(on: Input.start, starts: [StepDelay.self])
                fileprivate static func start(_ source: Ready) -> Change<Ready, Effect.Start> { fatalError() }

                @Transition(onSuccess: StepDelay.self, starts: [StepDelay.self])
                fileprivate static func present(
                    _ source: Ready,
                    request: StepDelayRequest,
                    routed step: Step
                ) -> Change<Comparing, Effect.Present> { fatalError() }

                @Transition(onSuccess: StepDelay.self)
                fileprivate static func finish(_ source: Ready) -> Finished { Finished() }

                @Route(onSuccess: StepDelay.self)
                fileprivate static func routeReady(_ source: Ready) -> Route.RouteReady { .finish }

                @Transition(onSuccess: StepDelay.self)
                fileprivate static func done(_ source: Comparing) -> Finished { Finished() }
            }
            """#
        let schema = try Self.parse(source)
        let op = try #require(schema.operations.first)
        #expect(op.producesVoid)
        let present = try #require(schema.transitions.first { $0.name == "present" })
        #expect(present.payloadType == nil)
        #expect(present.requestType == "StepDelayRequest")
        #expect(present.routedType == "Step")
        let finish = try #require(schema.transitions.first { $0.name == "finish" })
        #expect(!finish.takesRouted)
        let route = try #require(schema.routes.first)
        #expect(schema.hasRoutedPayload(route))
        #expect(schema.graphFindings().isEmpty)
    }

    @Test func routedChoiceVisibilityFollowsRouteAccessInPublicSchema() throws {
        let privateRoute = #"""
            @StateMachine(mode: .isolated)
            public enum Flow {
                fileprivate struct Handoff {}
                public struct Idle {}
                public struct Done {}

                @Initial case idle(Idle)
                @Terminal case done(Done)

                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func take(_ source: Idle, routed value: Handoff) -> Done { Done() }

                @Transition(on: Input.go)
                fileprivate static func stay(_ source: Idle) -> Idle { source }

                @Route(on: Input.go)
                fileprivate static func choose(_ source: Idle) -> Route.Choose { .stay }
            }
            """#
        let parsed = try Self.parse(privateRoute)
        let route = try #require(parsed.routes.first)
        #expect(parsed.choiceAccess(route) == .fileprivate)

        // Making the `@Route` itself public makes `Route.Choose` public, so `Handoff` must be public.
        let publicRoute = privateRoute.replacingOccurrences(
            of: "fileprivate static func choose",
            with: "public static func choose"
        )
        DiagnosticAnchorTests.expect(
            .init(
                name: "public route requires public routed type",
                source: publicRoute,
                message: "Declare 'Handoff' public:",
                needle: "Handoff"
            )
        )
    }

    @Test func routedChoiceVisibilityChecksNarrowedPackageInternalAliasesAndExternalTypes() throws {
        // Case A3a: public schema + package @Route + internal routed type.
        let publicSchemaPackageRoute = #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public nonisolated enum PackageRouteFlow {
                internal struct InternalStep { let x: Int }
                public struct A { public init() {} }
                public struct B { public let x: Int }
                @Initial case a(A = A())
                @Terminal case b(B)
                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: InternalStep) -> B { B(x: step.x) }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                package static func choose(_ source: A) -> Route.Choose { .take(InternalStep(x: 1)) }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "public schema package route rejects internal routed type at parameter",
                source: publicSchemaPackageRoute,
                message:
                    "Declare 'InternalStep' package or public, or narrow '@Route' 'choose' to internal or fileprivate: router 'choose' generates a package choice enum that names it.",
                needle: "InternalStep",
                occurrence: 2
            )
        )
        let validPackageStep = publicSchemaPackageRoute.replacingOccurrences(
            of: "internal struct InternalStep",
            with: "package struct InternalStep"
        )
        #expect(try Self.parse(validPackageStep).choiceAccess(Self.parse(validPackageStep).routes[0]) == .package)

        // Case A3c: public schema + omitted-access (internal) @Route + fileprivate routed type.
        let publicSchemaInternalRoute = #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local])
            public nonisolated enum InternalRouteFlow {
                fileprivate struct SecretStep { let x: Int }
                public struct A { public init() {} }
                public struct B { public let x: Int }
                @Initial case a(A = A())
                @Terminal case b(B)
                public enum Input { case go }

                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: SecretStep) -> B { B(x: step.x) }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                static func choose(_ source: A) -> Route.Choose { .take(SecretStep(x: 1)) }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "public schema internal route rejects fileprivate routed type at parameter",
                source: publicSchemaInternalRoute,
                message:
                    "Declare 'SecretStep' at least internal, or narrow '@Route' 'choose' to fileprivate: router 'choose' generates an internal choice enum that names it.",
                needle: "SecretStep",
                occurrence: 2
            )
        )
        let validInternalStep = publicSchemaInternalRoute.replacingOccurrences(
            of: "fileprivate struct SecretStep",
            with: "internal struct SecretStep"
        )
        #expect(try Self.parse(validInternalStep).choiceAccess(Self.parse(validInternalStep).routes[0]) == .internal)

        // Package schema + internal @Route + fileprivate routed type.
        let packageSchemaInternalRoute = publicSchemaInternalRoute.replacingOccurrences(
            of: "public nonisolated enum InternalRouteFlow",
            with: "package nonisolated enum InternalRouteFlow"
        )
        DiagnosticAnchorTests.expect(
            .init(
                name: "package schema internal route rejects fileprivate routed type at parameter",
                source: packageSchemaInternalRoute,
                message:
                    "Declare 'SecretStep' at least internal, or narrow '@Route' 'choose' to fileprivate: router 'choose' generates an internal choice enum that names it.",
                needle: "SecretStep",
                occurrence: 2
            )
        )

        // Internal schema + internal @Route + fileprivate routed type.
        let internalSchemaInternalRoute = #"""
            @StateMachine(mode: .isolated)
            enum LocalFlow {
                fileprivate struct Hidden {}
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go }
                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: Hidden) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                static func choose(_ source: A) -> Route.Choose { .stay }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "internal schema internal route rejects fileprivate routed type at parameter",
                source: internalSchemaInternalRoute,
                message:
                    "Declare 'Hidden' at least internal, or narrow '@Route' 'choose' to fileprivate: router 'choose' generates an internal choice enum that names it.",
                needle: "Hidden",
                occurrence: 2
            )
        )

        // Schema-local alias to an under-accessible target is followed and diagnosed at the routed parameter.
        let aliasedInternalTarget = #"""
            @StateMachine(mode: .isolated)
            public enum AliasedFlow {
                internal struct Inner {}
                package typealias StepAlias = Inner
                public struct A {}
                public struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                public enum Input { case go }
                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: StepAlias) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                package static func choose(_ source: A) -> Route.Choose { .stay }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "package route follows package alias to internal target",
                source: aliasedInternalTarget,
                message:
                    "Declare 'Inner' package or public, or narrow '@Route' 'choose' to internal or fileprivate: router 'choose' generates a package choice enum that names it.",
                needle: "StepAlias",
                occurrence: 2
            )
        )

        // Under-accessible alias to a public type is caught because generated `Route.Choose` spells the alias.
        let internalAliasToPublic = #"""
            @StateMachine(mode: .isolated)
            public enum InternalAliasFlow {
                typealias LocalAlias = Int
                public struct A {}
                public struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                public enum Input { case go }
                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: LocalAlias) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                package static func choose(_ source: A) -> Route.Choose { .stay }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "package route rejects internal alias to public type",
                source: internalAliasToPublic,
                message:
                    "Declare 'LocalAlias' package or public, or narrow '@Route' 'choose' to internal or fileprivate: router 'choose' generates a package choice enum that names it.",
                needle: "LocalAlias",
                occurrence: 2
            )
        )

        // Nested member inside a fileprivate container inherits fileprivate effective access.
        let nestedInsideFileprivate = #"""
            @StateMachine(mode: .isolated)
            public enum NestedHiddenFlow {
                fileprivate enum Box {
                    struct Step {}
                }
                public struct A {}
                public struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                public enum Input { case go }
                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: Box.Step) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                static func choose(_ source: A) -> Route.Choose { .stay }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "internal route rejects member nested in fileprivate container",
                source: nestedInsideFileprivate,
                message:
                    "Declare 'Box' at least internal, or narrow '@Route' 'choose' to fileprivate: router 'choose' generates an internal choice enum that names it.",
                needle: "Box.Step"
            )
        )

        // Private schema-local struct cannot appear even in a fileprivate choice enum inside Route.
        let privateSchemaStruct = #"""
            @StateMachine(mode: .isolated)
            public enum PrivateMemberFlow {
                private struct StrictSecret {}
                public struct A {}
                public struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                public enum Input { case go }
                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed step: StrictSecret) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func stay(_ source: A) -> A { source }
                @Route(on: Input.go)
                private static func choose(_ source: A) -> Route.Choose { .stay }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "private route still rejects schema-local private type used in nested Route choice enum",
                source: privateSchemaStruct,
                message:
                    "Declare 'StrictSecret' at least fileprivate: router 'choose' generates a fileprivate choice enum that names it.",
                needle: "StrictSecret",
                occurrence: 2
            )
        )

        // Legitimately hidden fileprivate types for fileprivate/private routers, external opaque types,
        // and generic aliases whose parameter shadows a fileprivate schema type are all preserved.
        let preservedCases = #"""
            @StateMachine(mode: .isolated)
            public enum PreservedFlow {
                fileprivate struct T {}
                public struct Box<U> { public let value: U }
                package typealias Identity<T> = Box<T>
                public struct A {}
                public struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                public enum Input { case hidden, external, genericAlias }

                @Transition(on: Input.hidden)
                fileprivate static func takeHidden(_ source: A, routed step: T) -> B { B() }
                @Transition(on: Input.hidden)
                fileprivate static func stayHidden(_ source: A) -> A { source }
                @Route(on: Input.hidden)
                private static func pickHidden(_ source: A) -> Route.PickHidden { .stayHidden }

                @Transition(on: Input.external)
                fileprivate static func takeExternal(_ source: A, routed step: ExternalOpaqueStep) -> B { B() }
                @Transition(on: Input.external)
                fileprivate static func stayExternal(_ source: A) -> A { source }
                @Route(on: Input.external)
                package static func pickExternal(_ source: A) -> Route.PickExternal { .stayExternal }

                @Transition(on: Input.genericAlias)
                fileprivate static func takeGeneric(_ source: A, routed step: Identity<Int>) -> B { B() }
                @Transition(on: Input.genericAlias)
                fileprivate static func stayGeneric(_ source: A) -> A { source }
                @Route(on: Input.genericAlias)
                package static func pickGeneric(_ source: A) -> Route.PickGeneric { .stayGeneric }
            }
            """#
        let preserved = try Self.parse(preservedCases)
        #expect(preserved.routes.count == 3)
        #expect(preserved.choiceAccess(preserved.routes[0]) == .fileprivate)
        #expect(preserved.choiceAccess(preserved.routes[1]) == .package)
        #expect(preserved.choiceAccess(preserved.routes[2]) == .package)
    }

    @Test func routedChoiceSharingDistinguishesPayloadsAccessAndAliases() throws {
        let matchingViaAlias = #"""
            @StateMachine(mode: .shared)
            public enum Flow {
                public typealias Count = Int
                public struct A {}
                public struct B {}
                public struct Done {}

                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)

                public enum Input { case step }

                @Transition(on: Input.step)
                fileprivate static func go(_ source: A, routed n: Int) -> B { B() }
                @Transition(on: Input.step)
                fileprivate static func skip(_ source: A) -> Done { Done() }
                @Route(on: Input.step)
                fileprivate static func pick(_ source: A) -> Route.Pick { .skip }

                @Transition(on: Input.step)
                fileprivate static func go(_ source: B, routed n: Count) -> Done { Done() }
                @Transition(on: Input.step)
                fileprivate static func skip(_ source: B) -> A { A() }
                @Route(on: Input.step)
                fileprivate static func pick(_ source: B) -> Route.Pick { .skip }
            }
            """#
        let matched = try Self.parse(matchingViaAlias)
        #expect(matched.sharesChoice("pick"))

        // Different routed type splits `Route.Pick` into phase-qualified choice enums.
        let mismatchedType =
            matchingViaAlias
            .replacingOccurrences(of: "routed n: Count", with: "routed n: String")
            .replacingOccurrences(of: "(_ source: A) -> Route.Pick", with: "(_ source: A) -> Route.A.Pick")
            .replacingOccurrences(of: "(_ source: B) -> Route.Pick", with: "(_ source: B) -> Route.B.Pick")
        let splitByType = try Self.parse(mismatchedType)
        #expect(!splitByType.sharesChoice("pick"))

        // Different route access splits `Route.Pick` so a public route never aliases a fileprivate choice.
        let mismatchedAccess =
            matchingViaAlias
            .replacingOccurrences(
                of: "fileprivate static func pick(_ source: B) -> Route.Pick",
                with: "public static func pick(_ source: B) -> Route.B.Pick"
            )
            .replacingOccurrences(of: "(_ source: A) -> Route.Pick", with: "(_ source: A) -> Route.A.Pick")
        let splitByAccess = try Self.parse(mismatchedAccess)
        #expect(!splitByAccess.sharesChoice("pick"))
        #expect(splitByAccess.choiceAccess(splitByAccess.routes[0]) == .fileprivate)
        #expect(splitByAccess.choiceAccess(splitByAccess.routes[1]) == .public)
    }

    @Test func routedOwnershipSendingAndShieldingRecordExpectedModelAndChecks() throws {
        let source = #"""
            @StateMachine(mode: .isolated)
            enum Flow {
                struct Handle: ~Copyable {}
                final class Box {}
                struct A {}
                struct B {}

                @Initial case a(A)
                @Terminal case b(B)

                enum Input { case go, send }

                @Transition(on: Input.go)
                fileprivate static func take(_ source: A, routed h: consuming Handle) -> B { B() }
                @Transition(on: Input.go)
                fileprivate static func drop(_ source: A) -> B { B() }
                @Route(on: Input.go)
                fileprivate static func routeGo(_ source: A) -> Route.RouteGo { .drop }

                @Transition(on: Input.send)
                fileprivate static func transfer(_ source: A, routed box: sending Box) -> B { B() }
                @Transition(on: Input.send)
                fileprivate static func keep(_ source: A) -> A { source }
                @Route(on: Input.send)
                fileprivate static func routeSend(_ source: A) -> Route.RouteSend { .keep }
            }
            """#
        let schema = try Self.parse(source)
        let routeGo = try #require(schema.routes.first { $0.name == "routeGo" })
        let routeSend = try #require(schema.routes.first { $0.name == "routeSend" })
        #expect(schema.choiceIsNoncopyable(routeGo))
        #expect(!schema.choiceIsNoncopyable(routeSend))
        #expect(schema.typeChecks.contains { $0.kind == .isSendable && $0.reference == "Box" })
    }

    @Test func routedRefusalsAnchorAtOffendingSyntax() {
        let base = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go(Int) }
                @Transition(on: Input.go)
                static func go(_ source: A, _ x: Int, routed y: Int) -> B { B() }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "unrouted transition with routed:",
                source: base,
                message: "Transition 'go' takes a routed: parameter, but no @Route selects it from 'A'.",
                needle: "routed y: Int"
            )
        )

        let routerWithRouted = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go }
                @Transition(on: Input.go)
                static func go(_ source: A) -> B { B() }
                @Route(on: Input.go)
                static func pick(_ source: A, routed y: Int) -> Route.Pick { .go }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "router taking routed:",
                source: routerWithRouted,
                message: "Only a candidate @Transition selected by a @Route may take a routed: parameter.",
                needle: "routed"
            )
        )

        let routedNotLast = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go(Int) }
                @Transition(on: Input.go)
                static func go(_ source: A, routed y: Int, _ x: Int) -> B { B() }
                @Route(on: Input.go)
                static func pick(_ source: A, _ x: Int) -> Route.Pick { .go(1) }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "routed: not last",
                source: routedNotLast,
                message: "Take the routed payload last, labeled routed:.",
                needle: "routed y: Int"
            )
        )

        let duplicateRouted = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go }
                @Transition(on: Input.go)
                static func go(_ source: A, routed x: Int, routed y: Int) -> B { B() }
                @Route(on: Input.go)
                static func pick(_ source: A) -> Route.Pick { .go(1) }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "duplicate routed:",
                source: duplicateRouted,
                message: "Take the routed payload once, in the last parameter, labeled routed:.",
                needle: "routed y: Int"
            )
        )

        let routedNever = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                typealias Impossible = Swift::Never
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go }
                @Transition(on: Input.go)
                static func go(_ source: A, routed bad: Impossible) -> B { B() }
                @Route(on: Input.go)
                static func pick(_ source: A) -> Route.Pick { fatalError() }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "routed: confirmed Never alias",
                source: routedNever,
                message: "Transition 'go' cannot take a routed: payload of type Never.",
                needle: "Impossible",
                occurrence: 2
            )
        )

        // Unconfirmed bare `Never` alias emits an expansion-time `.isNotNever` probe.
        let unconfirmedNever = routedNever.replacingOccurrences(of: "Swift::Never", with: "Never")
        let unconfirmedSchema = try? Self.parse(unconfirmedNever)
        #expect(
            unconfirmedSchema?.typeChecks
                .contains {
                    $0.kind == .isNotNever(message: "Transition 'go' cannot take a routed: payload of type Never.")
                        && $0.reference == "Impossible"
                } == true
        )

        let routedInOwnedOnly = #"""
            @StateMachine(mode: .ownedOnly)
            enum Flow: ~Copyable {
                struct A: ~Copyable {}
                struct B: ~Copyable {}
                @Initial case a(A)
                @Terminal case b(B)
                @Transition
                static func go(_ source: consuming A, routed y: Int) -> B { B() }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "routed: in ownedOnly",
                source: routedInOwnedOnly,
                message: "routed: requires a @Route, which is unavailable in .ownedOnly.",
                needle: "routed y: Int"
            )
        )

        let partiallyRoutedMultiSource = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                struct C {}
                struct Done {}
                @Initial case a(A)
                case b(B)
                case c(C)
                @Terminal case done(Done)
                enum Input { case next, go }
                @Transition(on: Input.next)
                static func toB(_ source: A) -> B { B() }
                @Transition(on: Input.next)
                static func toC(_ source: B) -> C { C() }
                @Transition(from: [A.self, B.self, C.self], on: Input.go)
                static func finish(routed tag: Int) -> Done { Done() }
                @Route(on: Input.go)
                static func pickA(_ source: A) -> Route.PickA { .finish(1) }
                @Route(on: Input.go)
                static func pickC(_ source: C) -> Route.PickC { .finish(2) }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "partially routed multi-source",
                source: partiallyRoutedMultiSource,
                message:
                    "Transition 'finish' takes a routed: parameter, but no @Route selects it from 'B'; every source phase in from: must be routed, or remove routed:.",
                needle: "routed tag: Int"
            )
        )
    }

    // MARK: - Feature 2: Generic `<Source>` on `@Transition(from:)`

    @Test func genericMultiSourceExpandsFixedSamePhasePhaseSetEffectsAndDeprecation() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Navigation {
                protocol SelectionCarrying { var selected: Int? { get set } }
                struct Browsing: SelectionCarrying { var selected: Int? }
                struct Confirming: SelectionCarrying { let tag: String; var selected: Int? }
                struct Presenting: SelectionCarrying { let sheet: String; var selected: Int? }

                @Initial case browsing(Browsing)
                case confirming(Confirming)
                case presenting(Presenting)

                enum Input { case select(Int?), show(String), confirm(String), back }

                @Event enum Tracked {}

                @PhaseSet([Browsing.self, Confirming.self, Presenting.self])
                fileprivate enum AllPhases {}

                @available(*, deprecated, message: "use something else")
                @Transition(from: AllPhases.self, on: Input.select, emits: [Tracked.self])
                fileprivate static func select<Source: SelectionCarrying>(
                    _ source: Source,
                    _ id: Int?
                ) -> Change<Source, Effect.Select> {
                    var next = source
                    next.selected = id
                    return Change(next, effects: [.tracked])
                }

                @Transition(from: [Browsing.self, Confirming.self], on: Input.show)
                fileprivate static func show<Source>(
                    _ source: Source,
                    _ sheet: String
                ) -> Presenting where Source: SelectionCarrying {
                    Presenting(sheet: sheet, selected: source.selected)
                }

                @Transition(on: Input.confirm)
                fileprivate static func confirm(_ source: Browsing, _ tag: String) -> Confirming {
                    Confirming(tag: tag, selected: source.selected)
                }

                @Transition(from: [Confirming.self, Presenting.self], on: Input.back)
                fileprivate static func back<Source: SelectionCarrying>(_ source: Source) -> Browsing {
                    Browsing(selected: source.selected)
                }
            }
            """#
        let schema = try Self.parse(source)
        let selects = schema.transitions.filter { $0.name == "select" }
        #expect(selects.map(\.from) == ["browsing", "confirming", "presenting"])
        #expect(selects.map(\.to) == ["browsing", "confirming", "presenting"])
        #expect(selects.map(\.sourceType) == ["Browsing", "Confirming", "Presenting"])
        #expect(
            selects.map(\.returnType) == [
                "Change<Browsing, Effect.Select>",
                "Change<Confirming, Effect.Select>",
                "Change<Presenting, Effect.Select>",
            ]
        )
        #expect(selects.allSatisfy { $0.isGenericSource && $0.preservesSourcePhase && $0.takesSource })
        #expect(selects.allSatisfy { $0.genericParameterClause == "<Source: SelectionCarrying>" })
        #expect(selects.allSatisfy { $0.genericWhereClause == nil })
        #expect(selects.allSatisfy { $0.sourceOwnership.isEmpty })
        for edge in selects {
            #expect(schema.fixedGeneratedNames.contains("_stateMachineGeneric\(edge.declaration)"))
        }
        #expect(
            selects.compactMap { $0.deprecation?.declaration } == [
                "static func select(_ argument0: Navigation.Browsing, _ argument1: Int?) -> Change<Navigation.Browsing, Effect.Select>",
                "static func select(_ argument0: Navigation.Confirming, _ argument1: Int?) -> Change<Navigation.Confirming, Effect.Select>",
                "static func select(_ argument0: Navigation.Presenting, _ argument1: Int?) -> Change<Navigation.Presenting, Effect.Select>",
            ]
        )

        let shows = schema.transitions.filter { $0.name == "show" }
        #expect(shows.map(\.from) == ["browsing", "confirming"])
        #expect(shows.map(\.to) == ["presenting", "presenting"])
        #expect(shows.allSatisfy { $0.isGenericSource && !$0.preservesSourcePhase })
        #expect(shows.allSatisfy { $0.genericParameterClause == "<Source>" })
        #expect(shows.allSatisfy { $0.genericWhereClause == "where Source: SelectionCarrying" })
        #expect(shows.allSatisfy { $0.sourceOwnership.isEmpty })
        for edge in shows {
            #expect(schema.fixedGeneratedNames.contains("_stateMachineGeneric\(edge.declaration)"))
        }
        let confirms = schema.transitions.filter { $0.name == "confirm" }
        #expect(confirms.allSatisfy { $0.genericParameterClause == nil && $0.genericWhereClause == nil })
        for edge in confirms {
            #expect(!schema.fixedGeneratedNames.contains("_stateMachineGeneric\(edge.declaration)"))
        }
        #expect(schema.graphFindings().isEmpty)
    }

    @Test func genericMultiSourceSupportsOwnedOnlyAdvanceAndComposesWithRouted() throws {
        let ownedOnly = #"""
            @StateMachine(mode: .ownedOnly)
            enum UniqueFlow: ~Copyable {
                protocol Titled: ~Copyable { var title: String { get set } }
                struct Draft: ~Copyable, Titled { var title: String }
                struct Review: ~Copyable, Titled { var title: String }
                enum RenameError: Error { case empty }

                @Initial case draft(Draft)
                case review(Review)

                @Transition
                fileprivate static func submit(_ source: consuming Draft) -> Review { Review(title: source.title) }

                @Transition(from: [Draft.self, Review.self])
                fileprivate static func rename<Source: Titled & ~Copyable>(
                    _ source: consuming Source
                ) -> Advance<Source, Source, Never, RenameError> { fatalError() }
            }
            """#
        let parsedOwnedOnly = try Self.parse(ownedOnly)
        let renames = parsedOwnedOnly.transitions.filter { $0.name == "rename" }
        #expect(renames.map(\.from) == ["draft", "review"])
        #expect(renames.map(\.to) == ["draft", "review"])
        #expect(
            renames.map(\.returnType) == [
                "Advance<Draft, Draft, Never, RenameError>",
                "Advance<Review, Review, Never, RenameError>",
            ]
        )
        #expect(renames.allSatisfy { $0.shape == .advance && $0.preservesSourcePhase })
        #expect(renames.allSatisfy { $0.genericParameterClause == "<Source: Titled & ~Copyable>" })
        #expect(renames.allSatisfy { $0.genericWhereClause == nil })
        #expect(renames.allSatisfy { $0.sourceOwnership == "consuming " })
        for edge in renames {
            #expect(parsedOwnedOnly.fixedGeneratedNames.contains("_stateMachineGeneric\(edge.declaration)"))
        }

        // Generic `from:` composing with `routed:` when every source phase is routed.
        let routedGeneric = #"""
            @StateMachine(mode: .shared)
            enum Composed {
                protocol Named { var name: String { get } }
                struct A: Named { let name: String }
                struct B: Named { let name: String }
                struct Done { let label: String }

                @Initial case a(A)
                case b(B)
                @Terminal case done(Done)

                enum Input { case move, finish }

                @Transition(on: Input.move)
                static func move(_ source: A) -> B { B(name: source.name) }

                @Transition(from: [A.self, B.self], on: Input.finish)
                static func finish<Source: Named>(_ source: Source, routed suffix: String) -> Done {
                    Done(label: source.name + suffix)
                }

                @Transition(on: Input.finish)
                static func stayA(_ source: A) -> A { source }
                @Route(on: Input.finish)
                static func pickA(_ source: A) -> Route.PickA { .stayA }

                @Transition(on: Input.finish)
                static func stayB(_ source: B) -> B { source }
                @Route(on: Input.finish)
                static func pickB(_ source: B) -> Route.PickB { .stayB }
            }
            """#
        let parsedComposed = try Self.parse(routedGeneric)
        let finishes = parsedComposed.transitions.filter { $0.name == "finish" }
        #expect(finishes.count == 2)
        #expect(finishes.allSatisfy { $0.isGenericSource && $0.routedType == "String" })
    }

    @Test func genericMultiSourceChecksEveryExpandedPhaseAndRejectsInvalidForms() {
        // Middle phase `B` is NOT in `Work`'s `activeIn`, while `A` and `C` are.
        let middlePhaseIneligible = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                struct C {}
                @Initial case a(A)
                case b(B)
                case c(C)
                enum Input { case next, pulse }
                @Operation(activeIn: [A.self, C.self])
                enum Work {}
                @Transition(on: Input.next)
                static func toB(_ source: A) -> B { B() }
                @Transition(on: Input.next)
                static func toC(_ source: B) -> C { C() }
                @Transition(on: Input.next)
                static func toA(_ source: C) -> A { A() }
                @Transition(from: [A.self, B.self, C.self], on: Input.pulse, starts: [Work.self])
                static func pulse<Source>(_ source: Source) -> Change<Source, Effect.Pulse> {
                    Change(source, effects: [.work])
                }
                @Transition(onSuccess: Work.self)
                static func doneA(_ source: A) -> A { source }
                @Transition(onSuccess: Work.self)
                static func doneC(_ source: C) -> C { source }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "same-phase starts ineligible in middle phase",
                source: middlePhaseIneligible,
                message: "Started operation 'Work' and every required scope must be eligible in destination 'B'.",
                needle: "Work.self"
            )
        )

        let base = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                case b(B)
                enum Input { case go(Int), flip }
                @Transition(on: Input.flip)
                static func flip(_ source: A) -> B { B() }
                @Transition(from: [A.self, B.self], on: Input.go)
                static func go<Source>(_ source: Source, _ x: Int) -> Source { source }
            }
            """#

        DiagnosticAnchorTests.expect(
            .init(
                name: "multiple generic parameters",
                source: DiagnosticAnchorTests.variant(base, "func go<Source>", "func go<Source, Extra>"),
                message:
                    "A multi-source transition may declare at most one generic type parameter for its source phase.",
                needle: "Extra"
            )
        )

        DiagnosticAnchorTests.expect(
            .init(
                name: "parameter pack generic",
                source: DiagnosticAnchorTests.variant(base, "func go<Source>", "func go<each Source>"),
                message:
                    "A multi-source transition's generic parameter must be a single type parameter for its source phase.",
                needle: "each Source"
            )
        )

        DiagnosticAnchorTests.expect(
            .init(
                name: "wrong first parameter type",
                source: DiagnosticAnchorTests.variant(base, "_ source: Source, _ x: Int", "_ source: A, _ x: Int"),
                message:
                    "Use the generic source parameter 'Source' as the first parameter of this multi-source transition.",
                needle: "A",
                occurrence: 5
            )
        )

        DiagnosticAnchorTests.expect(
            .init(
                name: "payload references generic Source",
                source: DiagnosticAnchorTests.variant(base, "_ x: Int", "_ x: Source"),
                message: "A trigger payload parameter cannot reference the generic source parameter 'Source'.",
                needle: "Source",
                occurrence: 3
            )
        )

        DiagnosticAnchorTests.expect(
            .init(
                name: "throws references generic Source",
                source: DiagnosticAnchorTests.variant(
                    base,
                    ") -> Source {",
                    ") throws(Source) -> Source {"
                ),
                message: "A thrown failure type cannot reference the generic source parameter 'Source'.",
                needle: "throws(Source)"
            )
        )

        let singleSourceGeneric = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                @Initial case a(A)
                enum Input { case go }
                @Transition(on: Input.go)
                static func go<Source>(_ source: Source) -> A { A() }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "generic single-source transition still refused",
                source: singleSourceGeneric,
                message:
                    "Use a synchronous nongeneric static function with nonvariadic parameters and no defaults, each unlabeled except a completion's request, labeled request:.",
                needle: "<Source>"
            )
        )

        let wrongAdvanceSource = #"""
            @StateMachine(mode: .ownedOnly)
            enum Flow: ~Copyable {
                struct A: ~Copyable {}
                struct B: ~Copyable {}
                enum Problem: Error { case bad }
                @Initial case a(A)
                case b(B)
                @Transition
                static func flip(_ source: consuming A) -> B { B() }
                @Transition(from: [A.self, B.self])
                static func keep<Source: ~Copyable>(_ source: consuming Source) -> Advance<A, Source, Never, Problem> {
                    fatalError()
                }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "ownedOnly Advance before type must be generic Source",
                source: wrongAdvanceSource,
                message: "Use the generic source parameter 'Source' as the source type of Advance.",
                needle: "A, Source"
            )
        )
    }

    @Test func genericMultiSourceRejectsSourceInEffectArgumentWhilePreservingSchemaQualifiedTypes() throws {
        // Case A5b: schema declares `typealias Source = Never`, and generic `<Source>` writes bare `Source`
        // in Advance's Effect position (which Swift binds to the generic parameter, not `Flow.Source`).
        let advanceBareSourceEffect = #"""
            @StateMachine(mode: .ownedOnly)
            nonisolated enum OwnedAdvanceShadowSource: ~Copyable {
                typealias Source = Never
                struct A: ~Copyable { let x: Int }
                struct B: ~Copyable { let x: Int }
                enum Fail: Error { case bad }
                @Initial case a(A)
                @Terminal case b(B)

                @Transition(from: [A.self])
                fileprivate static func go<Source: ~Copyable>(
                    _ source: consuming Source
                ) -> Advance<Source, B, Source, Fail> {
                    fatalError()
                }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "ownedOnly Advance effect rejects generic Source even when shadowed by schema alias",
                source: advanceBareSourceEffect,
                message: "Advance's effect type cannot reference the generic source parameter 'Source'.",
                needle: "Source, Fail"
            )
        )

        // Nested/parenthesized/member references to `<Source>` in Advance's Effect position are also rejected.
        DiagnosticAnchorTests.expect(
            .init(
                name: "Advance effect rejects parenthesized generic Source",
                source: DiagnosticAnchorTests.variant(
                    advanceBareSourceEffect,
                    "Advance<Source, B, Source, Fail>",
                    "Advance<Source, B, (Source), Fail>"
                ),
                message: "Advance's effect type cannot reference the generic source parameter 'Source'.",
                needle: "(Source)"
            )
        )
        DiagnosticAnchorTests.expect(
            .init(
                name: "Advance effect rejects member of generic Source",
                source: DiagnosticAnchorTests.variant(
                    advanceBareSourceEffect,
                    "Advance<Source, B, Source, Fail>",
                    "Advance<Source, B, Source.Nested, Fail>"
                ),
                message: "Advance's effect type cannot reference the generic source parameter 'Source'.",
                needle: "Source.Nested"
            )
        )

        // Legal schema-qualified forms (`OwnedAdvanceShadowSource.Source` and `Self.Source`) are preserved.
        let qualifiedSchemaSource = DiagnosticAnchorTests.variant(
            advanceBareSourceEffect,
            "Advance<Source, B, Source, Fail>",
            "Advance<Source, B, OwnedAdvanceShadowSource.Source, Fail>"
        )
        let parsedQualified = try Self.parse(qualifiedSchemaSource)
        #expect(
            parsedQualified.transitions.first?.returnType
                == "Advance<A, B, OwnedAdvanceShadowSource.Source, Fail>"
        )

        let selfQualifiedSource = DiagnosticAnchorTests.variant(
            advanceBareSourceEffect,
            "Advance<Source, B, Source, Fail>",
            "Advance<Source, B, Self.Source, Fail>"
        )
        let parsedSelfQualified = try Self.parse(selfQualifiedSource)
        #expect(parsedSelfQualified.transitions.first?.returnType == "Advance<A, B, Self.Source, Fail>")

        // Change<After, Effect> also rejects bare, wrapped, and member references to the generic parameter,
        // including when the generic parameter is named `Effect` (shadowing `Flow.Effect`).
        let changeBase = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                @Terminal case b(B)
                enum Input { case go }
                @Event enum Tracked {}

                @Transition(from: [A.self], on: Input.go, emits: [Tracked.self])
                fileprivate static func go<Source>(_ source: Source) -> Change<B, Source> {
                    fatalError()
                }
            }
            """#
        DiagnosticAnchorTests.expect(
            .init(
                name: "Change effect rejects bare generic Source",
                source: changeBase,
                message: "Change's effect type cannot reference the generic source parameter 'Source'.",
                needle: "Source>",
                occurrence: 2
            )
        )
        DiagnosticAnchorTests.expect(
            .init(
                name: "Change effect rejects generic Source inside wrapper",
                source: DiagnosticAnchorTests.variant(changeBase, "Change<B, Source>", "Change<B, Box<Source>>"),
                message: "Change's effect type cannot reference the generic source parameter 'Source'.",
                needle: "Box<Source>"
            )
        )
        DiagnosticAnchorTests.expect(
            .init(
                name: "Change effect rejects generic parameter named Effect shadowing Flow.Effect",
                source: DiagnosticAnchorTests.variant(
                    changeBase,
                    "func go<Source>(_ source: Source) -> Change<B, Source>",
                    "func go<Effect>(_ source: Effect) -> Change<B, Effect.Go>"
                ),
                message: "Change's effect type cannot reference the generic source parameter 'Effect'.",
                needle: "Effect.Go"
            )
        )

        // Legal schema-qualified `Flow.Effect.Go` and `Self.Effect.Go` still parse when generic param is `Effect`.
        let qualifiedChangeEffect = DiagnosticAnchorTests.variant(
            changeBase,
            "func go<Source>(_ source: Source) -> Change<B, Source>",
            "func go<Effect>(_ source: Effect) -> Change<B, Flow.Effect.Go>"
        )
        let parsedChangeQualified = try Self.parse(qualifiedChangeEffect)
        #expect(parsedChangeQualified.transitions.first?.returnType == "Change<B, Flow.Effect.Go>")

        let selfQualifiedChangeEffect = DiagnosticAnchorTests.variant(
            changeBase,
            "func go<Source>(_ source: Source) -> Change<B, Source>",
            "func go<Effect>(_ source: Effect) -> Change<B, Self.Effect.Go>"
        )
        let parsedSelfChangeQualified = try Self.parse(selfQualifiedChangeEffect)
        #expect(parsedSelfChangeQualified.transitions.first?.returnType == "Change<B, Self.Effect.Go>")
    }
}
