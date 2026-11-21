import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Every family of aliases either reads in full, or is diagnosed at the declaration that spells it.
///
/// The macro reads only the aliases a graph reaches, only the arguments an alias's spelling uses, and a
/// chain of aliases that each name the next without nesting. A reading that would pass a step or
/// nesting budget is diagnosed rather than read as a guess, and either outcome takes time linear in the
/// declarations.
struct ReadingCostTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }

    /// The diagnostic of a declaration whose reading passes a budget.
    static let budgetMessage =
        "This type nests too deeply, or reaches its type through too many aliases, for the macro to read it; spell it directly or through fewer aliases."

    /// A schema with one operation whose `Output` is `output`, among `declarations`; its success edge
    /// takes the output unless it is `Void`.
    private static func schema(output: String, declarations: String, void: Bool = false) -> String {
        TypeResolutionTests.loading(
            aliases: "typealias Output = \(output)",
            declarations: declarations,
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running\(void ? "" : ", _ value: Load.Output")) -> Idle { fatalError() }"
        )
    }

    /// Parses and generates `source`, requiring both to finish within a bound that leaves the work
    /// linear in the declarations.
    private static func measure(_ source: String, _ check: (Schema) throws -> Void = { _ in }) throws {
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let schema = try parse(source)
            try check(schema)
            _ = try Generator(schema: schema).members()
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    /// Requires `source` to be diagnosed with the budget's message, within the same bound.
    private static func measureDiagnosed(_ source: String) {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(DeclarationHygieneTests.diagnostics(source) == [budgetMessage])
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    /// Requires `source` either to read in full, as `check` confirms, or to be diagnosed with the
    /// budget's message: a test's thread has less stack than the macro's, so the deepest families may
    /// reach the nesting budget there and not in the compiler.
    private static func measureReadOrDiagnosed(_ source: String, _ check: (Schema) throws -> Void) throws {
        guard let messages = DeclarationHygieneTests.diagnostics(source) else {
            try measure(source, check)
            return
        }
        #expect(messages == [budgetMessage])
    }

    /// `First<X, Y> = X` with each level using its predecessor twice, through different arguments: the
    /// reported family, whose eager reading doubled at every level.
    static func doublingThroughUnusedArguments(depth: Int) -> String {
        var declarations = ["struct L<T> {}", "struct R<T> {}", "typealias First<X, Y> = X", "typealias A0<T> = ()"]
        for level in 1 ... depth {
            declarations.append("typealias A\(level)<T> = First<A\(level - 1)<L<T>>, A\(level - 1)<R<T>>>")
        }
        return declarations.joined(separator: "; ")
    }

    @Test func aFamilyNoReadingReachesIsNeverRead() throws {
        let declarations = Self.doublingThroughUnusedArguments(depth: 64)
        try Self.measure(Self.schema(output: "Swift::Int", declarations: declarations)) { schema in
            #expect(!schema.typeScopes.exhaustedBudget)
        }
    }

    /// An argument an alias does not use is never read, and one its spelling is itself is read in place,
    /// so the reported family reads in full at any depth.
    @Test func anArgumentAnAliasDoesNotUseIsNeverRead() throws {
        let declarations = Self.doublingThroughUnusedArguments(depth: 64)
        for depth in [24, 64] {
            try Self.measure(Self.schema(output: "A\(depth)<Swift::Int>", declarations: declarations, void: true)) {
                schema in
                let operation = try #require(schema.operations.first)
                #expect(operation.producesVoid)
                #expect(schema.typeScopes.resolve("A\(depth)<Swift::Int>").isVoid)
                #expect(!schema.typeScopes.exhaustedBudget)
            }
        }
    }

    /// Each level uses its predecessor three times through different arguments, so its reading grows
    /// threefold; the step budget cuts it short, and the declaration is diagnosed rather than guessed.
    @Test func fanOutThroughSeveralParametersIsDiagnosedAtItsBudget() {
        var declarations = [
            "struct L<T> {}", "struct M<T> {}", "struct R<T> {}", "typealias Triple<A, B, C> = (A, B, C)",
            "typealias P0<T> = T",
        ]
        for level in 1 ... 40 {
            declarations.append(
                "typealias P\(level)<T> = Triple<P\(level - 1)<L<T>>, P\(level - 1)<M<T>>, P\(level - 1)<R<T>>>"
            )
        }
        Self.measureDiagnosed(
            Self.schema(output: "P40<Swift::Int>", declarations: declarations.joined(separator: "; "))
        )
    }

    /// One argument used several times is read once, so a tree of repeated uses is read in linear steps,
    /// and a key that would outgrow its budget keeps the kind of type it reads as.
    @Test func repeatedUsesOfOneArgumentAreReadOnce() throws {
        var declarations = ["typealias Triple<A, B, C> = (A, B, C)", "typealias S0<T> = T"]
        for level in 1 ... 64 {
            declarations.append("typealias S\(level)<T> = Triple<S\(level - 1)<T>, S\(level - 1)<T>, S\(level - 1)<T>>")
        }
        let text = declarations.joined(separator: "; ")
        try Self.measure(Self.schema(output: "S16<Swift::Int>", declarations: text)) { schema in
            let reading = schema.typeScopes.resolve("S16<Swift::Int>")
            #expect(reading.reading == .visible && reading.confirmsShape)
            #expect(!reading.key.exceeds(LexicalScopes.keyBudget))
            #expect(!schema.typeScopes.exhaustedBudget)
        }
        try Self.measureReadOrDiagnosed(Self.schema(output: "S64<Swift::Int>", declarations: text)) { schema in
            #expect(schema.typeScopes.resolve("S64<Swift::Int>").reading == .visible)
        }
    }

    /// Aliases that name each other with a growing argument read in linear steps; one that names itself
    /// is a cycle.
    @Test func mutuallyRecursiveGrowthIsBoundedOrACycle() throws {
        var declarations = ["typealias E0<T> = T"]
        for level in 1 ... 56 {
            declarations.append(
                level % 2 == 0
                    ? "typealias E\(level)<T> = E\(level - 1)<[T]>" : "typealias E\(level)<T> = E\(level - 1)<T?>"
            )
        }
        let text = declarations.joined(separator: "; ")
        try Self.measure(Self.schema(output: "E16<Swift::Int>", declarations: text)) { schema in
            #expect(schema.typeScopes.resolve("E16<Swift::Int>").reading == .visible)
        }
        try Self.measureReadOrDiagnosed(Self.schema(output: "E56<Swift::Int>", declarations: text)) { schema in
            #expect(schema.typeScopes.resolve("E56<Swift::Int>").reading == .visible)
        }
        let cyclic = Self.schema(
            output: "Even<Swift::Int>",
            declarations: "typealias Even<T> = Odd<[T]>; typealias Odd<T> = Even<T?>"
        )
        #expect(
            DeclarationHygieneTests.diagnostics(cyclic) == [
                "Type alias 'Even' names itself, directly or through other aliases; give it a type that does not depend on it."
            ]
        )
    }

    /// A chain of aliases that each name the next reads in one frame, however long it is: nongeneric,
    /// generic, and a chain whose apparent cycle an extension could break, which reads as an unconfirmed
    /// opaque type with every link read once.
    @Test func longLinearChainsReadIteratively() throws {
        let plain = (0 ..< 5_000).map { "typealias B\($0) = B\($0 + 1)" }.joined(separator: "; ")
        try Self.measure(Self.schema(output: "B0", declarations: plain + "; typealias B5000 = Swift::Int")) { schema in
            #expect(schema.typeScopes.resolve("B0").key == .standard("Int"))
            #expect(!schema.typeScopes.exhaustedBudget)
        }
        let generic = (["typealias G0<T> = T"] + (1 ... 3_000).map { "typealias G\($0)<T> = G\($0 - 1)<T>" })
            .joined(separator: "; ")
        try Self.measure(Self.schema(output: "G3000<()>", declarations: generic, void: true)) { schema in
            // The output is `Void`, so the success edge, which takes nothing after its source, is its own.
            let operation = try #require(schema.operations.first)
            #expect(operation.producesVoid)
            #expect(schema.typeScopes.resolve("G3000<Swift::Int>").key == .standard("Int"))
            #expect(!schema.typeScopes.exhaustedBudget)
        }
        let links = (0 ..< 1_536).map { "typealias Link\($0) = Link\($0 + 1)" }.joined(separator: "; ")
        try Self.measure(
            Self.schema(
                output: "Link0",
                declarations: links + "; typealias Link1536 = Nested.Last; enum Nested { typealias Last = Link0 }"
            )
        ) { schema in
            let reading = schema.typeScopes.resolve("Link0")
            #expect(reading.isOpaque && !reading.isConfirmed && !reading.isCut)
            #expect(schema.typeScopes.circularAliases.isEmpty)
        }
    }

    /// Nested uses of a generic alias that names its parameter read in place.
    @Test func nestedGenericAliasesReadToDepthForty() throws {
        var nested = "Swift::Int"
        for _ in 0 ..< 40 { nested = "Id<\(nested)>" }
        try Self.measure(Self.schema(output: nested, declarations: "typealias Id<T> = T")) { schema in
            #expect(schema.typeScopes.resolve(nested).key == .standard("Int"))
        }
    }

    /// A reading that nests past its budget through the structure its aliases spell is diagnosed at the
    /// declaration that spells it.
    @Test func aReadingPastItsNestingBudgetIsDiagnosed() {
        let wrapping = (["typealias W0 = Swift::Int"] + (1 ... 2_000).map { "typealias W\($0) = [W\($0 - 1)]" })
            .joined(separator: "; ")
        let generic = (["typealias V0<T> = T"] + (1 ... 2_000).map { "typealias V\($0)<T> = [V\($0 - 1)<T>]" })
            .joined(separator: "; ")
        // A chain of nongeneric aliases keeps each one's reading, so it does not nest.
        #expect(DeclarationHygieneTests.diagnostics(Self.schema(output: "W2000", declarations: wrapping)) == nil)
        Self.measureDiagnosed(Self.schema(output: "V2000<Swift::Int>", declarations: generic))
    }

    /// Structure spends the step budget as aliases do, charged and checked at every type it reads: a
    /// tuple, a function's parameters, a composition, or a pack's arguments wider than the budget is
    /// diagnosed at the declaration that spells it, and its siblings past the cut are left unread.
    @Test func wideStructuresSpendTheStepBudget() {
        let count = LexicalScopes.stepBudget + 1
        func list(_ element: String, _ separator: String = ", ") -> String {
            Array(repeating: element, count: count).joined(separator: separator)
        }
        for output in [
            "(\(list("()")))", "(\(list("Swift::Int"))) -> ()", "any \(list("P", " & "))",
            "Pack<\(list("Swift::Int"))>",
        ] {
            Self.measureDiagnosed(Self.schema(output: output, declarations: "protocol P {}; struct Pack<each T> {}"))
        }
    }

    /// A deferred argument keeps the aliases being read where it was spelled as one node of a tree that
    /// every stack shares, so a chain whose links each wrap the argument they pass on keeps one record
    /// per link, not a copy of the stack per argument.
    @Test func deferredArgumentsShareTheStackTheyWereSpelledIn() throws {
        for links in [384, 2_304] {
            let chain = (["typealias G0<T> = ()"] + (1 ... links).map { "typealias G\($0)<T> = G\($0 - 1)<[T]>" })
                .joined(separator: "; ")
            try Self.measure(Self.schema(output: "G\(links)<Swift::Int>", declarations: chain, void: true)) { schema in
                let operation = try #require(schema.operations.first)
                #expect(operation.producesVoid)
                #expect(schema.typeScopes.retainedVisits <= links + 1, "\(schema.typeScopes.retainedVisits)")
                #expect(!schema.typeScopes.exhaustedBudget)
            }
        }
    }

    /// Doubling chains and wide tuples read in steps proportional to their text, and a key that would
    /// double past its budget keeps its kind.
    @Test func doublingChainsAndWideTuplesAreLinear() throws {
        let doubling = (1 ... 60).map { "typealias D\($0) = (D\($0 - 1), D\($0 - 1))" }.joined(separator: "; ")
        try Self.measure(Self.schema(output: "D60", declarations: "typealias D0 = Swift::Int; " + doubling)) { schema in
            let reading = schema.typeScopes.resolve("D60")
            #expect(reading.reading == .visible && reading.confirmsShape)
            #expect(!reading.key.exceeds(LexicalScopes.keyBudget))
        }
        let wide = "(" + Array(repeating: "Swift::Int", count: 2_000).joined(separator: ", ") + ")"
        let widening = (1 ... 30).map { "typealias W\($0) = (W\($0 - 1), W\($0 - 1), W\($0 - 1), W\($0 - 1))" }
            .joined(separator: "; ")
        try Self.measure(Self.schema(output: "W30", declarations: "typealias W0 = \(wide); " + widening)) { schema in
            #expect(schema.typeScopes.resolve("W30").reading == .visible)
        }
        // A generic alias's reading whose key outgrows its budget keeps a function type's kind.
        let handler = (1 ... 9).map { "typealias H\($0) = (H\($0 - 1), H\($0 - 1))" }.joined(separator: "; ")
        let source = TypeResolutionTests.loading(
            aliases: "typealias Input = @Sendable (H9) -> Swift::Void",
            declarations: "typealias H0 = Swift::Int; typealias Handler<T> = @Sendable ((T, T)) -> Swift::Void; "
                + handler,
            edges: "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running) -> Idle { fatalError() }"
        )
        try Self.measure(source) { schema in
            let operation = try #require(schema.operations.first)
            #expect(operation.inputEscapes)
            let reading = schema.typeScopes.resolve("Handler<H9>")
            #expect(reading.isConfirmedFunction && !reading.key.exceeds(LexicalScopes.keyBudget))
        }
    }

    // MARK: Work counts

    /// The work of reading `output` among `declarations`, without generating anything.
    private static func work(output: String, declarations: String) throws -> (LexicalScopes.Work, ResolvedType) {
        let schema = try parse(Self.schema(output: output, declarations: declarations))
        let reading = schema.typeScopes.resolve("Load.Output")
        return (schema.typeScopes.work, reading)
    }

    /// The work of reading `output` among `declarations` whose reading the budget cuts short, read
    /// without the schema, which its diagnostic rejects.
    private static func cutWork(output: String, declarations: String) throws -> (LexicalScopes.Work, ResolvedType) {
        let file = Parser.parse(source: Self.schema(output: output, declarations: declarations))
        let declaration = try #require(file.statements.first?.item.as(EnumDeclSyntax.self))
        let scopes = LexicalScopes(declaration)
        let reading = scopes.resolve("Load.Output")
        return (scopes.work, reading)
    }

    /// A tuple of aliases, each a generic alias of an alias not read yet, is read inside one chain whose
    /// readings wait and are undone: each undoes only what it changed, so the changes logged and undone
    /// grow with the elements, not with the elements already read.
    @Test func speculativeReadingsAreUndoneInProportionToWhatTheyChanged() throws {
        func tuple(_ count: Int) -> (output: String, declarations: String) {
            (
                "(" + (0 ..< count).map { "A\($0)" }.joined(separator: ", ") + ")",
                "typealias Id<T> = T; "
                    + (0 ..< count).map { "typealias A\($0) = Id<U\($0)>; typealias U\($0) = Swift::Int" }
                    .joined(separator: "; ")
            )
        }
        var counts: [Int: LexicalScopes.Work] = [:]
        for count in [500, 1_000, 2_000] {
            let (work, reading) = try Self.work(output: tuple(count).output, declarations: tuple(count).declarations)
            #expect(!reading.isCut && reading.confirmsShape)
            #expect(work.logged <= 6 * count + 8, "\(work)")
            #expect(work.undone <= 3 * count + 8, "\(work)")
            #expect(work.steps <= 12 * count + 16, "\(work)")
            counts[count] = work
        }
        // Doubling the tuple at most doubles each count, give or take the schema's own few readings.
        for (small, large) in [(500, 1_000), (1_000, 2_000)] {
            let (a, b) = (try #require(counts[small]), try #require(counts[large]))
            #expect(b.logged <= 2 * a.logged + 16 && b.undone <= 2 * a.undone + 16 && b.steps <= 2 * a.steps + 16)
        }
    }

    /// A deferred argument is keyed by its spelling, computed once per syntax node, and by the number of
    /// the arguments it is read with, so an alias with many parameters whose arguments it never reads
    /// spells and hashes each argument a constant number of times rather than once per argument.
    @Test func deferredArgumentsAreKeyedByTheNumberOfTheirArguments() throws {
        for count in [1_000, 4_000] {
            let parameters = (0 ..< count).map { "T\($0)" }.joined(separator: ", ")
            let wrapped = (0 ..< count).map { "[T\($0)]" }.joined(separator: ", ")
            let declarations =
                "typealias Ignore<\(parameters)> = Swift::Int; typealias Wrapper<\(parameters)> = Ignore<\(wrapped)>"
            let output = "Wrapper<" + Array(repeating: "Swift::Int", count: count).joined(separator: ", ") + ">"
            let (work, reading) = try Self.work(output: output, declarations: declarations)
            #expect(!reading.isCut && reading.isVoid == false)
            #expect(work.spelled <= 2 * count + 4, "\(work)")
            #expect(work.hashed <= 2 * count + 4, "\(work)")
            #expect(work.steps <= 3 * count + 16, "\(work)")
        }
    }

    /// Each argument of a use of a generic alias is charged a step, so an alias with many parameters
    /// expanded many times spends the budget in proportion to the arguments it is expanded with, and a
    /// family past the budget is diagnosed rather than read without bound.
    @Test func everyGenericArgumentIsChargedToTheBudget() throws {
        func family(_ count: Int) -> (output: String, declarations: String) {
            let parameters = (0 ..< count).map { "T\($0)" }.joined(separator: ", ")
            let wrapped = (0 ..< count).map { "[T\($0)]" }.joined(separator: ", ")
            let uses = Array(repeating: "U", count: count).joined(separator: ", ")
            return (
                "(" + (0 ..< count).map { "X<C\($0)>" }.joined(separator: ", ") + ")",
                "typealias Ignore<\(parameters)> = Swift::Int; typealias W<\(parameters)> = Ignore<\(wrapped)>; "
                    + "typealias X<U> = W<\(uses)>; " + (0 ..< count).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        }
        let (read, reading) = try Self.work(output: family(100).output, declarations: family(100).declarations)
        #expect(!reading.isCut)
        #expect(read.steps >= 2 * 100 * 100 && read.steps <= 3 * 100 * 100, "\(read)")
        let (cut, cutReading) = try Self.cutWork(output: family(400).output, declarations: family(400).declarations)
        #expect(cutReading.isCut)
        #expect(cut.steps <= LexicalScopes.stepBudget + 1, "\(cut)")
        Self.measureDiagnosed(Self.schema(output: family(400).output, declarations: family(400).declarations))
    }

    /// Telling cycles apart charges each link it follows and checks the budget at each one, so a ring
    /// whose aliases each name many others stops at the budget, in the first search.
    @Test func theCycleSearchStopsAtTheBudget() throws {
        let ring = (0 ..< 1_000)
            .map { index in
                "typealias R\(index) = (" + (1 ... 60).map { "R\((index + $0) % 1_000)" }.joined(separator: ", ") + ")"
            }
            .joined(separator: "; ")
        let (work, reading) = try Self.cutWork(output: "R0", declarations: ring)
        #expect(reading.isCut)
        #expect(work.steps <= LexicalScopes.stepBudget + 1, "\(work)")
        Self.measureDiagnosed(Self.schema(output: "R0", declarations: ring))
    }

    // MARK: Work that grows with the declarations, family by family

    /// The work of reading `family(count)` at each count, which must grow at most in proportion.
    private static func scaling(
        _ counts: [Int],
        _ family: (Int) -> (output: String, declarations: String),
        _ check: (Int, LexicalScopes.Work, ResolvedType) throws -> Void = { _, _, _ in }
    ) throws -> [LexicalScopes.Work] {
        var works: [LexicalScopes.Work] = []
        for count in counts {
            let (output, declarations) = family(count)
            let (work, reading) = try Self.work(output: output, declarations: declarations)
            try check(count, work, reading)
            works.append(work)
        }
        for (small, large) in zip(works, works.dropFirst()) {
            #expect(large.steps <= 2 * small.steps + 64, "\(small) then \(large)")
            // Names spelled with more digits as the count grows lengthen the spellings a little.
            #expect(large.numbered <= 3 * small.numbered + 64, "\(small) then \(large)")
            #expect(large.walked <= 2 * small.walked + 64 && large.flattened <= 2 * small.flattened + 64)
        }
        return works
    }

    /// A deferred argument is found by the number of its spelling, so an alias that ignores a long tuple
    /// argument, expanded with many bindings, hashes the tuple's spelling once rather than once for
    /// every binding.
    @Test func aDeferredArgumentsSpellingIsHashedOnce() throws {
        let tuple = "(" + Array(repeating: "T", count: 200).joined(separator: ", ") + ")"
        let works = try Self.scaling([250, 500, 1_000]) { count in
            (
                "(" + (0 ..< count).map { "X<C\($0)>" }.joined(separator: ", ") + ")",
                "typealias Ignore<A, B> = Swift::Int; typealias X<T> = Ignore<\(tuple), T>; "
                    + (0 ..< count).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        } _: { _, _, reading in
            #expect(!reading.isCut)
        }
        // The tuple is spelled once however many bindings it is read with: what grows is the bindings' own
        // short spellings, one each.
        for (count, work) in zip([250, 500, 1_000], works) {
            #expect(work.numbered <= 2 * tuple.utf8.count + 8 * count, "\(work)")
        }
    }

    /// A value argument is charged a step as a type argument is, and spelled once per syntax node, so a
    /// generic alias that spells many values, expanded many times, spends the budget in proportion.
    @Test func valueArgumentsAreChargedAndSpelledOnce() throws {
        let values = Array(repeating: "0", count: 100).joined(separator: ", ")
        func family(_ count: Int) -> (output: String, declarations: String) {
            (
                "(" + (0 ..< count).map { "X<C\($0)>" }.joined(separator: ", ") + ")",
                "struct Dimensions<T> {}; typealias X<T> = (T, Dimensions<\(values)>); "
                    + (0 ..< count).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        }
        let works = try Self.scaling([100, 200, 400], family) { count, work, reading in
            #expect(!reading.isCut)
            #expect(work.steps >= 100 * count, "\(work)")
            #expect(work.spelled <= 100 + count + 8, "\(work)")
        }
        #expect(works.count == 3)
        let (cut, reading) = try Self.cutWork(output: family(2_000).output, declarations: family(2_000).declarations)
        #expect(reading.isCut && cut.steps <= LexicalScopes.stepBudget + 1, "\(cut)")
    }

    /// A use of a wide generic alias with the wrong number of arguments is read as opaque in steps for its
    /// own arguments, whatever the alias's width, so many such uses take time linear in the uses.
    @Test func aMistypedUseOfAWideAliasIsCheckedInConstantWork() throws {
        func family(width: Int) -> (output: String, declarations: String) {
            let parameters = (0 ..< width).map { "T\($0)" }.joined(separator: ", ")
            return (
                "(" + (0 ..< 3_000).map { "Wide<C\($0)>" }.joined(separator: ", ") + ")",
                "typealias Wide<\(parameters)> = Swift::Int; "
                    + (0 ..< 3_000).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        }
        let (narrow, _) = try Self.work(output: family(width: 30).output, declarations: family(width: 30).declarations)
        let (wide, reading) = try Self.work(
            output: family(width: 3_000).output,
            declarations: family(width: 3_000).declarations
        )
        #expect(!reading.isCut && reading.isOpaque == false)
        // The alias's width changes nothing a use of it reads.
        #expect(wide.steps == narrow.steps, "\(narrow) against \(wide)")
        try Self.measure(
            Self.schema(output: family(width: 3_000).output, declarations: family(width: 3_000).declarations)
        )
    }

    /// Reading a deferred argument where a deep chain spelled it, from a shallow alias that shares it,
    /// charges each node of the stack the move walks, so the walk spends the budget rather than
    /// running outside it.
    @Test func movingToADeferredArgumentChargesItsWalk() throws {
        func family(depth: Int, arguments: Int) -> (output: String, declarations: String) {
            let parameters = (0 ..< arguments).map { "A\($0)" }.joined(separator: ", ")
            let spelled = (0 ..< arguments).map { "(T, P\($0))" }.joined(separator: ", ")
            return (
                "(F\(depth)<C0>, S<C0>)",
                "typealias Ignore<\(parameters)> = Swift::Int; typealias Use<\(parameters)> = (\(parameters)); "
                    + "typealias F0<T> = Ignore<\(spelled)>; "
                    + (1 ... depth).map { "typealias F\($0)<T> = F\($0 - 1)<T>" }.joined(separator: "; ")
                    + "; typealias S<T> = Use<\(spelled)>; struct C0 {}; "
                    + (0 ..< arguments).map { "struct P\($0) {}" }.joined(separator: "; ")
            )
        }
        let small = family(depth: 200, arguments: 20)
        let (work, reading) = try Self.work(output: small.output, declarations: small.declarations)
        #expect(!reading.isCut)
        #expect(work.walked >= 2 * 200 * 20 && work.steps >= work.walked, "\(work)")
        let large = family(depth: 2_000, arguments: 60)
        let (cut, cutReading) = try Self.cutWork(output: large.output, declarations: large.declarations)
        #expect(cutReading.isCut)
        #expect(cut.steps <= LexicalScopes.stepBudget + 2 * 2_000 + 8, "\(cut)")
        Self.measureDiagnosed(Self.schema(output: large.output, declarations: large.declarations))
    }

    /// A composition flattens a composition it names once, by whatever spelling it names it, and charges
    /// each member it flattens in, so the members gathered grow with the distinct members.
    @Test func aCompositionFlattensEachCompositionOnce() throws {
        let protocols = (0 ..< 1_000).map { "protocol P\($0) {}" }.joined(separator: "; ")
        let all = "typealias All = " + (0 ..< 1_000).map { "P\($0)" }.joined(separator: " & ")
        let works = try Self.scaling([1_000, 2_000, 4_000]) { count in
            (
                "any " + (0 ..< count).map { $0.isMultiple(of: 2) ? "All" : "Flow.All" }.joined(separator: " & "),
                protocols + "; " + all
            )
        } _: { count, work, reading in
            #expect(!reading.isCut)
            // The schema reads the output's spelling twice, through its alias and as spelled, and each
            // reading flattens `All` once, however many times and by whichever spelling it is named.
            #expect(work.flattened <= 2 * 1_000 + 8, "\(work)")
            #expect(work.steps <= 6 * count + 4 * 1_000 + 64, "\(work)")
        }
        #expect(works.count == 3)
    }

    /// An alias that waits on many others is read again once all of them are read, however soon the first
    /// is, so a tuple whose first element reads at once while the others wait reads in linear steps.
    @Test func aWaitingAliasIsReadAgainOnce() throws {
        let works = try Self.scaling([500, 1_000, 2_000]) { count in
            (
                "Waiting",
                "typealias Waiting = (First, " + (0 ..< count).map { "B\($0)" }.joined(separator: ", ")
                    + "); typealias First = [Swift::Int]; "
                    + (0 ..< count).map { "typealias B\($0) = [C\($0)]; typealias C\($0) = [Swift::Int]" }
                    .joined(separator: "; ")
            )
        } _: { count, work, reading in
            #expect(!reading.isCut)
            #expect(work.steps <= 12 * count + 64, "\(work)")
        }
        #expect(works.count == 3)
    }

    /// A name read in a nested scope is looked up through every enclosing scope it passes, each charged a
    /// step, so many names read deep in nested types spend the budget in proportion to the depth.
    @Test func lookingThroughEnclosingScopesIsCharged() throws {
        func family(depth: Int, uses: Int) -> (output: String, declarations: String) {
            let path = (1 ... depth).map { "S\($0)" }.joined(separator: ".")
            let deep = "typealias Deep = (" + Array(repeating: "Top", count: uses).joined(separator: ", ") + ")"
            let nested = (1 ... depth).reduce(deep) { inner, level in "enum S\(depth - level + 1) { \(inner) }" }
            return ("\(path).Deep", "typealias Top = Swift::Int; " + nested)
        }
        // The parser nests no deeper than its own limit, which is lower in a debug build.
        let small = family(depth: 8, uses: 500)
        let (work, reading) = try Self.work(output: small.output, declarations: small.declarations)
        #expect(!reading.isCut)
        #expect(work.steps >= 8 * 500, "\(work)")
        let large = family(depth: 8, uses: 15_000)
        let (cut, cutReading) = try Self.cutWork(output: large.output, declarations: large.declarations)
        #expect(cutReading.isCut && cut.steps <= LexicalScopes.stepBudget + 1, "\(cut)")
    }

    /// Whether functions of one name throw different types is decided once for the expansion, reading
    /// each function's failure once, rather than once for every `PreparationRejection` case it names, so
    /// many throwing edges of one name, from as many phases, generate in time linear in the edges.
    @Test func manyThrowingEdgesOfOneNameGenerateInLinearTime() throws {
        let count = 300
        let phases = (0 ..< count).map { "struct P\($0) {}; \($0 == 0 ? "@Initial " : "")case p\($0)(P\($0))" }
        let edges = (0 ..< count)
            .map {
                "@Transition(on: Input.go)\nstatic func step(_ source: P\($0)) throws(Problem\($0 % 2)) -> P\(($0 + 1) % count) { fatalError() }"
            }
        let source = """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Problem0: Error {}
                struct Problem1: Error {}
                \(phases.joined(separator: "\n"))
                enum Input { case go }
                \(edges.joined(separator: "\n"))
            }
            """
        try Self.measure(source) { schema in
            #expect(schema.namesThrowingDifferentFailures == ["step"])
        }
    }

    /// The dispatch finds each phase's edges and routers for each trigger once and visits only the pairs
    /// that have one, so a graph with many phases, inputs, and edges, each phase leaving through its own
    /// input, generates in time linear in its edges rather than in phases times inputs times edges.
    @Test func manyPhasesAndInputsDispatchInLinearTime() throws {
        let count = 500
        let phases = (0 ..< count).map { "struct P\($0) {}; \($0 == 0 ? "@Initial " : "")case p\($0)(P\($0))" }
        let inputs = (0 ..< count).map { "go\($0)(Swift::Int)" }.joined(separator: ", ")
        let edges = (0 ..< count)
            .map {
                "@Transition(on: Input.go\($0))\nstatic func go\($0)(_ source: P\($0), _ value: Swift::Int) -> P\(($0 + 1) % count) { fatalError() }"
            }
        let source = """
            @StateMachine(mode: .shared)
            enum Flow {
                \(phases.joined(separator: "\n"))
                enum Input { case \(inputs) }
                \(edges.joined(separator: "\n"))
            }
            """
        try Self.measure(source)
    }

    /// One phase with many routed triggers, each choosing between two edges back to the phase: the
    /// routers' candidates, choice types, and shared names are found once for the schema, so validation and
    /// generation take time linear in the routers.
    @Test func manyRoutedTriggersOfOnePhaseDispatchInLinearTime() throws {
        let count = 400
        let inputs = (0 ..< count).map { "go\($0)(Swift::Int)" }.joined(separator: ", ")
        let functions = (0 ..< count)
            .map {
                """
                @Route(on: Input.go\($0))
                static func pick\($0)(_ source: Idle, _ value: Swift::Int) -> Route.Pick\($0) { fatalError() }
                @Transition(on: Input.go\($0))
                static func stay\($0)(_ source: Idle, _ value: Swift::Int) -> Idle { fatalError() }
                @Transition(on: Input.go\($0))
                static func keep\($0)(_ source: Idle, _ value: Swift::Int) -> Idle { fatalError() }
                """
            }
        let source = """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case \(inputs) }
                \(functions.joined(separator: "\n"))
            }
            """
        try Self.measure(source)
    }

    /// A key's nodes are counted as it is built, so keeping many readings whose keys are near the key
    /// budget takes no walk of each key, and their work is linear in the uses.
    @Test func keysNearTheBudgetAreKeptWithoutAWalk() throws {
        let doubling = (1 ... 9).map { "typealias D\($0) = (D\($0 - 1), D\($0 - 1))" }.joined(separator: "; ")
        _ = try Self.scaling([500, 1_000, 2_000]) { count in
            (
                "(" + (0 ..< count).map { "H<C\($0)>" }.joined(separator: ", ") + ")",
                "typealias D0 = Swift::Int; " + doubling + "; typealias H<T> = (D9, T); "
                    + (0 ..< count).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        } _: { _, _, reading in
            #expect(!reading.isCut)
        }
        let uses = "(" + (0 ..< 2_000).map { "H<C\($0)>" }.joined(separator: ", ") + ")"
        try Self.measure(
            Self.schema(
                output: uses,
                declarations: "typealias D0 = Swift::Int; " + doubling + "; typealias H<T> = (D9, T); "
                    + (0 ..< 2_000).map { "struct C\($0) {}" }.joined(separator: "; ")
            )
        )
    }
}
