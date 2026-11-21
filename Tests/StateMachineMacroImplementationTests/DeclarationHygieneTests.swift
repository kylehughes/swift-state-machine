import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import Testing

@testable import StateMachineMacros

/// Generated names are validated where they are emitted, and type spellings resolve where they are used.
struct DeclarationHygieneTests {
    static func parse(_ text: String) throws -> Schema {
        let syntax = Parser.parse(source: text)
        guard let declaration = syntax.statements.first?.item.as(EnumDeclSyntax.self),
            let attribute = declaration.attributes.first?.as(AttributeSyntax.self)
        else { fatalError("Malformed test fixture") }
        return try Schema.parse(declaration, attribute: attribute)
    }

    static func diagnostics(_ text: String) -> [String]? {
        do {
            _ = try parse(text)
            return nil
        } catch let error as DiagnosticsError {
            return error.diagnostics.map(\.message)
        } catch {
            return ["\(error)"]
        }
    }

    /// Two routers whose names differ only in their first letter generate the same `Route.Choose`.
    @Test func routersWhoseChoiceTypesCollideAreDiagnosed() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go, back }
                @Transition(on: Input.go)
                static func left(_ source: Idle) -> Busy { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) -> Idle { fatalError() }
                @Route(on: Input.go)
                static func choose(_ source: Idle) -> Route.Choose { fatalError() }
                @Transition(on: Input.back)
                static func up(_ source: Busy) -> Idle { fatalError() }
                @Transition(on: Input.back)
                static func down(_ source: Busy) -> Busy { fatalError() }
                @Route(on: Input.back)
                static func Choose(_ source: Busy) -> Route.Choose { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Router 'Choose' would generate Route.Choose, which router 'choose' also generates; rename one."
            ]
        )
    }

    /// `pickResult` is usable when `pick` returns its candidates' common result and generates no `Route.PickResult`.
    @Test func aRouterNameIsFreeWhenNoRouterGeneratesItsResultType() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go, back }
                @Transition(on: Input.go)
                static func left(_ source: Idle) -> Busy { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) -> Busy { fatalError() }
                @Route(on: Input.go)
                static func pick(_ source: Idle) -> Route.Pick { fatalError() }
                @Transition(on: Input.back)
                static func up(_ source: Busy) -> Idle { fatalError() }
                @Transition(on: Input.back)
                static func down(_ source: Busy) -> Busy { fatalError() }
                @Route(on: Input.back)
                static func pickResult(_ source: Busy) -> Route.PickResult { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.routes.map(\.name) == ["pick", "pickResult"])
        // The same pair collides once `pick` can throw, because its owned method then returns Route.PickResult.
        let throwing = source.replacingOccurrences(
            of: "func pick(_ source: Idle) -> Route.Pick",
            with: "func pick(_ source: Idle) throws(Problem) -> Route.Pick"
        )
        #expect(
            Self.diagnostics(throwing) == [
                "Router 'pickResult' would generate Route.PickResult, which router 'pick' also generates; rename one."
            ]
        )
    }

    /// A throwing completion router's owned result has a `rejected` case, so no candidate may use that name.
    @Test func aThrowingCompletionRouterCannotChooseAnEdgeNamedRejected() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Loading {}
                @Initial case idle(Idle)
                case loading(Loading)
                enum Input { case start }
                @Operation(activeIn: [Loading.self])
                enum Fetch { typealias Input = Int; typealias Output = Int }
                @Transition(on: Input.start, starts: [Fetch.self])
                static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func accepted(_ source: Loading, _ output: Int) -> Idle { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func rejected(_ source: Loading, _ output: Int) -> Loading { fatalError() }
                @Route(onSuccess: Fetch.self)
                static func screen(_ source: Loading, _ output: Int) throws(Problem) -> Route.Screen { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "A throwing router cannot choose an edge named 'rejected', which its owned result uses; rename the edge."
            ]
        )
    }

    /// An `Input` case's payload is kept as the author spelled it, which means what it means inside `Input`,
    /// where Swift resolves it, a type an extension of `Input` declares included; generated code reads it only
    /// through the case.
    @Test func inputPayloadsKeepTheirAuthoredSpelling() throws {
        let source = #"""
            @StateMachine(mode: .isolated)
            enum Lookup {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input {
                    final class Request {}
                    actor Session {}
                    struct Plain {}
                    case lookup(Request)
                    case attach(Session)
                    case note(Plain)
                    case named([Request])
                }
                @Transition(on: Input.lookup)
                static func lookup(_ source: Idle, _ request: Input.Request) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(
            schema.inputs.map(\.payloadType) == ["Request", "Session", "Plain", "[Request]"]
        )
    }

    /// An input payload that spans lines is shown on one line and stays one escaped graph literal.
    @Test func graphLiteralsEscapeAuthoredText() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Pairs {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case pair((Int, // first
                    Int)), quoted([String: Int]) }
                @Transition(on: Input.pair)
                static func pair(_ source: Idle, _ value: (Int, Int)) -> Idle { fatalError() }
                @Transition(on: Input.quoted)
                static func quoted(_ source: Idle, _ value: [String: Int]) -> Idle { fatalError() }
            }
            """#
        let members = try Generator(schema: Self.parse(source)).members()
        let malformed = members.filter { $0.hasError }
        #expect(malformed.isEmpty)
        let graph = try #require(members.first { $0.description.contains("func _stateMachineGraph()") })
        #expect(graph.description.contains(#"payload: "(Int, Int)""#))
        #expect(graph.description.contains(#"payload: "[String: Int]""#))
    }

    /// `Self` inside the schema names the schema wherever generated code repeats an edge's spelling, and an
    /// `Input` payload keeps `Self`, which names `Input` where it is written.
    @Test func selfKeepsItsLexicalMeaning() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Lookup {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input {
                    final class Request {}
                    case lookup(Self.Request)
                }
                @Transition(on: Input.lookup)
                static func lookup(_ source: Idle, _ request: Self.Input.Request) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.inputs.first?.payloadType == "Self.Request")
        #expect(schema.transitions.first?.payloadType == "Lookup.Input.Request")
    }

    /// A payload naming a type nested in `Input` whose name needs backticks, a raw identifier or `Type`,
    /// keeps its authored spelling, backticks and all, in the schema and in the graph.
    @Test func namesThatNeedBackticksKeepThem() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Lookup {
                struct `N.P` {}
                struct `Type` {}
                struct Idle {}
                @Initial case idle(Idle)
                enum Input {
                    struct `N.P` {}
                    struct `Type` {}
                    struct Plain {}
                    case raw(`N.P`)
                    case selfRaw(Self.`N.P`)
                    case type(`Type`)
                    case plain(`Plain`)
                }
                @Transition(on: Input.raw)
                static func raw(_ source: Idle, _ value: Input.`N.P`) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.inputs.map(\.payloadType) == ["`N.P`", "Self.`N.P`", "`Type`", "`Plain`"])
        let graph = try #require(
            try Generator(schema: schema).members().first { $0.description.contains("func _stateMachineGraph()") }
        )
        #expect(graph.description.contains(#"payload: "`N.P`""#))
        #expect(graph.description.contains(#"payload: "Self.`N.P`""#))
    }

    /// An operation's driver and an event's handler share one initializer's parameter list.
    @Test func aDriverLabelThatIsAnEventHandlerLabelIsDiagnosed() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Printer {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case print }
                @Operation(activeIn: [Idle.self])
                enum OnPrint {}
                @Event enum PrintDriver {}
                @Transition(on: Input.print, starts: [OnPrint.self], emits: [PrintDriver.self])
                static func print(_ source: Idle) -> Change<Idle, Effect.Print> { fatalError() }
                @Transition(onSuccess: OnPrint.self)
                static func printed(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Operation 'OnPrint' and event 'PrintDriver' both name the managed initializer parameter 'onPrintDriver', the operation's driver and the event's handler; rename one."
            ]
        )
        // Without a managed owner there is no initializer to share.
        #expect(
            Self.diagnostics(source.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.local]"))
                == nil
        )
    }

    /// A routed edge is called through `self`, so a parameter of the router's method cannot hide it.
    @Test func routedEdgesAreCalledThroughSelf() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Named {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go(Int), pick(Int) }
                @Operation(activeIn: [Busy.self])
                enum Fetch { typealias Input = Int }
                @Transition(on: Input.go, starts: [Fetch.self])
                static func go(_ source: Idle, _ value: Int) -> Change<Busy, Effect.Go> { fatalError() }
                @Transition(on: Input.pick)
                static func input(_ source: Idle, _ value: Int) -> Idle { fatalError() }
                @Transition(on: Input.pick)
                static func ignore(_ source: Idle, _ value: Int) -> Idle { fatalError() }
                @Route(on: Input.pick)
                static func choose(_ source: Idle, _ value: Int) -> Route.Choose { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func request(_ source: Busy, request: FetchRequest) -> Idle { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func stay(_ source: Busy, request: FetchRequest) -> Busy { fatalError() }
                @Route(onSuccess: Fetch.self)
                static func settle(_ source: Busy, request: FetchRequest) -> Route.Settle { fatalError() }
            }
            """#
        let text = try Generator(schema: Self.parse(source)).members().map(\.description).joined()
        #expect(text.contains("case .request: return .request(self.request(request: request))"))
        #expect(text.contains("case .input: return self.input(input)"))
    }

    /// Generated code qualifies the runtime's types, so a schema may declare types of the same names.
    @Test func runtimeTypeNamesAreFreeForAuthoredTypes() throws {
        for name in ["RuntimeIsolatedHost", "RuntimeState", "RuntimeScopeID", "RuntimeKey", "PlanRejection", "Limits"] {
            let source = #"""
                @StateMachine(mode: .isolated)
                enum Flow {
                    struct Idle {}
                    struct \#(name) {}
                    @Initial case idle(Idle)
                    enum Input { case go }
                    @Transition(on: Input.go)
                    static func go(_ source: Idle) -> Idle { fatalError() }
                }
                """#
            #expect(Self.diagnostics(source) == nil, "'\(name)' is free")
        }
    }

    /// Every reserved name is a member the expansion declares, a name a generated owner declares inside
    /// itself, where it would shadow a schema type, or one of the few names generated code spells
    /// without a module: the short results authored edges return and the modules themselves.
    @Test func everyReservedNameIsDeclaredOrSpelledByTheExpansion() throws {
        let spelled: Set<String> = [
            "Phase", "Owner", "Host", "Drivers", "CompletionPolicy", "InitialPhase", "RestorationArchive",
            "RestorationRejection", "Change", "Advance", "StateMachine", "Swift",
        ]
        func owners(_ list: String, mode: String = ".shared", in source: String = GraphStructureTests.base) -> String {
            source.replacingOccurrences(of: "mode: .shared", with: "mode: \(mode), owners: \(list)")
        }
        let restorable = GraphStructureTests.base.replacingOccurrences(
            of: "enum Input",
            with:
                "@Restoration\n    static func restore(_ saved: Int) throws(Problem) -> Restoration { fatalError() }\n    enum Input"
        )
        let sources = [
            GraphStructureTests.base, restorable, owners("[.local]"), owners("[.owned]"), owners("[.shared]"),
            owners("[.actorHost]"), owners("[.isolatedHost]", mode: ".isolated"),
            owners("[.mainActorHost]", mode: ".isolated"), owners("[.local]", in: restorable),
            owners("[.isolatedHost]", in: restorable), GraphStructureTests.tracked,
            owners("[.local]", in: GraphStructureTests.tracked), owners("[.owned]", in: GraphStructureTests.tracked),
        ]
        for source in sources {
            let schema = try Self.parse(source)
            let declared = Set(
                try Generator(schema: schema).members()
                    .flatMap { member -> [String] in
                        if let named = member.asProtocol(NamedDeclSyntax.self) { return [named.name.text] }
                        if let variable = member.as(VariableDeclSyntax.self) {
                            return variable.bindings.compactMap {
                                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                            }
                        }
                        return []
                    }
            )
            let reserved = schema.reservedNames
            #expect(declared.subtracting(reserved).isEmpty, "\(schema.owners): \(declared.subtracting(reserved))")
            #expect(
                reserved.subtracting(declared).subtracting(spelled).isEmpty,
                "\(schema.owners): \(reserved.subtracting(declared).subtracting(spelled).sorted())"
            )
        }
    }

    /// The qualifier that moves a spelling out of the declaration that wrote it rewrites `Self` and the names
    /// it is given wherever the spelling names a type, and only there; an `Input` payload, which generated
    /// code never moves, keeps the author's spelling.
    @Test func qualificationFollowsTheSyntaxOfTypes() throws {
        func qualified(_ spelling: String) -> String {
            TypeQualifier.qualify(TypeSyntax(stringLiteral: spelling), owner: "Input", names: ["Key"])
        }
        // A dictionary's key type is a type, not a tuple label.
        #expect(qualified("[Key: Int]") == "[Input.Key: Int]")
        #expect(qualified("[Key: [Key: Key]]") == "[Input.Key: [Input.Key: Input.Key]]")
        #expect(qualified("(key: Key, value: Int)") == "(key: Input.Key, value: Int)")
        #expect(qualified("(Key) -> Key?") == "(Input.Key) -> Input.Key?")
        #expect(qualified("Array<Self.Key>") == "Array<Input.Key>")
        // A member after a period and an attribute keep their spelling.
        #expect(qualified("Swift.Set<Key>") == "Swift.Set<Input.Key>")
        #expect(qualified("@Sendable (Key) -> Void") == "@Sendable (Input.Key) -> Void")
        #expect(qualified("[Key /* id */: Int]") == "[Input.Key /* id */: Int]")
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial @Terminal case idle(Idle)
                enum Input {
                    struct Key: Hashable {}
                    case update([Key /* id */: Self.Key])
                }
            }
            """#
        // The graph shows it as written, with the comment as one space.
        #expect(try Self.parse(source).inputs.first?.payloadType == "[Key : Self.Key]")
    }

    /// Generated code spells every standard-library type through `Swift`, so a schema may declare
    /// types of the same names.
    @Test func standardLibraryNamesAreFreeForAuthoredTypes() throws {
        let names = [
            "Actor", "Array", "Bool", "CaseIterable", "ContinuousClock", "Copyable", "CustomStringConvertible",
            "Equatable", "Error", "Hashable", "Int", "MainActor", "Never", "Result", "Sendable", "String", "UInt32",
            "UInt64", "Void",
        ]
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow: Hashable {
                struct Idle: Swift.Hashable {}
                struct Busy: Swift.Hashable {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go(Swift.Int) }
                @Operation(activeIn: [Busy.self])
                enum Fetch { typealias Key = Swift.Int }
                @Transition(on: Input.go, starts: [Fetch.self])
                static func go(_ source: Idle, _ key: Swift.Int) -> Change<Busy, Effect.Go> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        for name in names {
            let declaring = source.replacingOccurrences(of: "struct Idle", with: "struct \(name) {}\n    struct Idle")
            #expect(Self.diagnostics(declaring) == nil, "'\(name)' is free")
        }
        let members = try Generator(schema: Self.parse(source)).members().map(\.description).joined()
        #expect(members.contains("_OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable>"))
        #expect(members.contains("enum Effect: Swift::Sendable, Swift::Hashable"))
        // Generated code names modules through selectors, so the module names are free as well; an
        // authored spelling through such a member then means the member, as Swift reads it.
        for module in ["Swift", "StateMachine"] {
            #expect(
                Self.diagnostics(
                    source.replacingOccurrences(of: "struct Idle", with: "enum \(module) {}\n    struct Idle")
                ) == nil
            )
        }
    }

    /// A name is reserved only by the selection whose expansion declares it.
    @Test func generatedCaseNamesAreReservedOnlyWhereTheyAreGenerated() {
        // A throwing router's `rejected` case belongs to its `Owned` result.
        let routed = #"""
            @StateMachine(mode: .shared, owners: [.local])
            enum Flow {
                enum Problem: Error { case bad }
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case go }
                @Route(on: Input.go)
                static func pick(_ source: Idle) throws(Problem) -> Route.Pick { fatalError() }
                @Transition(on: Input.go)
                static func rejected(_ source: Idle) -> Done { fatalError() }
                @Transition(on: Input.go)
                static func accepted(_ source: Idle) -> Done { fatalError() }
            }
            """#
        #expect(Self.diagnostics(routed) == nil)
        #expect(
            Self.diagnostics(routed.replacingOccurrences(of: "owners: [.local]", with: "owners: [.local, .owned]")) == [
                "A throwing router cannot choose an edge named 'rejected', which its owned result uses; rename the edge."
            ]
        )
        // `invalidPhase` is a case of `PreparationRejection`, which only an observing owner has.
        let throwing = #"""
            @StateMachine(mode: .shared, owners: [.owned])
            enum Flow {
                enum Problem: Error { case bad }
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case go }
                @Transition(on: Input.go)
                static func invalidPhase(_ source: Idle) throws(Problem) -> Done { fatalError() }
            }
            """#
        #expect(Self.diagnostics(throwing) == nil)
        #expect(
            Self.diagnostics(throwing.replacingOccurrences(of: "owners: [.owned]", with: "owners: [.owned, .local]"))
                == [
                    "'invalidPhase' is already a PreparationRejection case; rename this throwing transition."
                ]
        )
        // A keyed operation has cancellation cases only when some edge lists it in `cancels:`.
        let keyed = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Loading {}
                @Initial case idle(Idle)
                case loading(Loading)
                enum Input { case go(Int), stop }
                @Operation(activeIn: [Loading.self])
                enum Fetch { typealias Key = Int }
                @Event enum CancelFetch {}
                @Transition(on: Input.go, starts: [Fetch.self])
                static func go(_ source: Idle, _ key: Int) -> Change<Loading, Effect.Go> { fatalError() }
                @Transition(on: Input.stop, emits: [CancelFetch.self])
                static func stop(_ source: Loading) -> Change<Idle, Effect.Stop> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Loading) -> Idle { fatalError() }
            }
            """#
        #expect(Self.diagnostics(keyed) == nil)
        #expect(
            Self.diagnostics(
                keyed.replacingOccurrences(
                    of: "emits: [CancelFetch.self]",
                    with: "cancels: [Fetch.self], emits: [CancelFetch.self]"
                )
            )
                == [
                    "Event 'CancelFetch' generates the effect case 'cancelFetch', which keyed operation 'Fetch' uses to cancel its work; rename one.",
                    "Keyed operation 'Fetch' generates the effect case 'cancelFetch' to cancel one key's work, which event 'CancelFetch' also generates; rename one.",
                ]
        )
    }

    /// Effect and choice lists declare what an edge may return, so their order does not decide whether
    /// edges of one name share a type.
    @Test func edgesShareEffectAndChoiceTypesWhateverTheirListOrder() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                @Initial case a(A)
                case b(B)
                enum Input { case tap, pick }
                @Event enum Logged {}
                @Event enum Tracked {}
                @Transition(on: Input.tap, emits: [Logged.self, Tracked.self])
                static func tap(_ source: A) -> Change<B, Effect.Tap> { fatalError() }
                @Transition(on: Input.tap, emits: [Tracked.self, Logged.self])
                static func tap(_ source: B) -> Change<A, Effect.Tap> { fatalError() }
                @Transition(on: Input.pick)
                static func left(_ source: A) -> A { fatalError() }
                @Transition(on: Input.pick)
                static func right(_ source: A) -> B { fatalError() }
                @Transition(on: Input.pick)
                static func right(_ source: B) -> B { fatalError() }
                @Transition(on: Input.pick)
                static func left(_ source: B) -> A { fatalError() }
                @Route(on: Input.pick)
                static func choose(_ source: A) -> Route.Choose { fatalError() }
                @Route(on: Input.pick)
                static func choose(_ source: B) -> Route.Choose { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(
            schema.transitions.filter { $0.name == "tap" }.map { schema.effectType($0) } == [
                "Effect.Tap", "Effect.Tap",
            ]
        )
        #expect(schema.routes.map { schema.choiceType($0) } == ["Route.Choose", "Route.Choose"])
        // Different vocabularies still have only their phase-qualified names.
        let different = source.replacingOccurrences(
            of: "emits: [Tracked.self, Logged.self]",
            with: "emits: [Tracked.self]"
        )
        #expect(
            Self.diagnostics(different) == ["This transition emits Logged, Tracked; name its effects Effect.A.Tap."]
        )
    }

    /// A `Snapshot` case beside a `Snapshot` property of its name is a different declaration, so a phase
    /// may take the name of any `Snapshot` member, whatever the owners.
    @Test func phaseCasesMayShareTheNamesOfSnapshotMembers() throws {
        let source = #"""
            @StateMachine(mode: .shared, owners: [.owned])
            enum Modeled {
                struct Ready {}
                @Initial @Terminal case model(Ready)
                enum Input {}
            }
            """#
        for name in ["record", "model", "revision", "isClosed", "description"] {
            for owners in ["[.owned]", "[.local]", "[.shared]"] {
                let named = source.replacingOccurrences(of: "case model(", with: "case \(name)(")
                    .replacingOccurrences(of: "owners: [.owned]", with: "owners: \(owners)")
                #expect(Self.diagnostics(named) == nil, "\(name) \(owners)")
            }
        }
    }
}
