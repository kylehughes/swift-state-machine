import SwiftParser
import SwiftSyntax

#if canImport(Darwin)
import Darwin
#endif

extension TokenSyntax {
    /// The text of the token, with an identifier read without backticks that change nothing:
    /// `` `Phase` `` and `Phase` name one declaration.
    ///
    /// An escaped identifier keeps its backticks when its bare spelling means something else in a
    /// type, as `` `Type` `` does after a period, or is no ordinary identifier by Swift's own lexer, as
    /// a keyword or a raw identifier with a space is. Every other token keeps its text.
    var unescaped: String {
        guard case .identifier = tokenKind, let name = identifier?.name, name != text else { return text }
        return name.spelledAsName
    }

    /// The name an identifier declares or looks up, without any backticks.
    ///
    /// `` `Type` `` declares the name a bare `Type` looks up where no period precedes it, where only a
    /// metatype's `.Type` is a keyword. A keyword, such as `Self` or `Any`, keeps its text, so it never
    /// looks up a declaration.
    var lookupName: String {
        guard case .identifier = tokenKind, let name = identifier?.name else { return text }
        return name
    }
}

extension TokenSyntax {
    /// The value of an integer literal token, read as Swift reads it: decimal digits, or `0x`, `0o`, or
    /// `0b` and digits of that base, with any `_` between them ignored; `nil` for another token, and for
    /// a value too large for `UInt`.
    ///
    /// It is the one reader of integer literals: an admission limit and a value generic argument are read
    /// through it, so `10`, `1_0`, and `0xA` are one value wherever the macro compares them.
    var integerLiteralMagnitude: UInt? {
        guard case .integerLiteral(let text) = tokenKind else { return nil }
        let digits = text.filter { $0 != "_" }
        let bases: [(prefix: String, radix: Int)] = [("0x", 16), ("0o", 8), ("0b", 2)]
        guard let base = bases.first(where: { digits.hasPrefix($0.prefix) }) else { return UInt(digits, radix: 10) }
        return UInt(digits.dropFirst(2), radix: base.radix)
    }
}

extension ExprSyntax {
    /// The value of an integer literal, `-` and a literal included, as an `Int`, through
    /// ``TokenSyntax/integerLiteralMagnitude``; `nil` for any other expression, and for a value `Int`
    /// cannot represent.
    var integerLiteralValue: Int? {
        if let literal = self.as(IntegerLiteralExprSyntax.self) {
            return literal.literal.integerLiteralMagnitude.flatMap { Int(exactly: $0) }
        }
        guard let negated = self.as(PrefixOperatorExprSyntax.self), negated.operator.text == "-",
            negated.operator.trailingTrivia.isEmpty,
            let magnitude = negated.expression.as(IntegerLiteralExprSyntax.self)?.literal.integerLiteralMagnitude,
            magnitude <= UInt(Int.max) + 1
        else { return nil }
        return magnitude == UInt(Int.max) + 1 ? Int.min : -Int(magnitude)
    }
}

extension String {
    /// The source text of a type's name, as stored without backticks: the name bare where Swift reads it
    /// bare as that name in any position of a type, after a period included, and in backticks otherwise,
    /// as a keyword, a raw identifier such as `` `N.P` ``, and `` `Type` `` need.
    ///
    /// Every name the macro stores is its ``TokenSyntax/lookupName``, which tables key and lookups compare;
    /// this is the one way back to source text.
    var spelledAsName: String {
        guard !["Type", "Protocol", "Self", "Any", "self"].contains(self), isValidSwiftIdentifier(for: .variableName)
        else { return "`" + self + "`" }
        return self
    }
}

/// The syntax of each type spelling an expansion stores as text, so reading a spelling again never parses it
/// again: parsing nested brackets takes time that doubles with each level, as SwiftParser's lookahead for an
/// inline array tries each `[` both ways.
///
/// A spelling kept exactly as the author wrote it is read from the author's syntax; any other, which the
/// macro composed, is parsed once, the first time it is read.
final class SpellingSyntax {
    private var types: [String: TypeSyntax] = [:]
    /// The spellings parsed so far, each once: those the macro composed.
    private(set) var parsed: Set<String> = []

    /// The syntax of `spelling`.
    func type(_ spelling: String) -> TypeSyntax {
        if let type = types[spelling] { return type }
        let type = TypeSyntax(stringLiteral: spelling)
        types[spelling] = type
        parsed.insert(spelling)
        return type
    }

    /// Records `node` as the syntax of `spelling` when `spelling` is exactly its text.
    func remember(_ node: TypeSyntax, as spelling: String) {
        guard types[spelling] == nil, node.trimmedDescription == spelling else { return }
        types[spelling] = node
    }
}

/// A name in a key, compared, hashed, and ordered by the number the reader gives its text when it first
/// sees it, so a long name is hashed once, where it is numbered, however many keys hold it.
///
/// Numbers are given in reading order, so the order of two names holds for one expansion; keys use it
/// only to put a composition's members and a type's attributes in one canonical order, never to print.
struct KeyName: Hashable, Comparable, CustomStringConvertible {
    let number: Int
    let text: String

    static func == (lhs: KeyName, rhs: KeyName) -> Bool { lhs.number == rhs.number }

    func hash(into hasher: inout Hasher) { hasher.combine(number) }

    static func < (lhs: KeyName, rhs: KeyName) -> Bool { lhs.number < rhs.number }

    var description: String { text }
}

/// The identity of the type a spelling names, as a tree: spellings of one type share one key, and
/// spellings of types the compiler tells apart never do.
///
/// Each composite type keeps its structure, so a metatype of a function, a function of a metatype, an
/// optional function, and a function of an optional are different keys whatever their tokens. Every name
/// in a key is a ``KeyName``, and keys are ordered by their structure, never by how they print: a nested
/// protocol `N.P` and a protocol named by the raw identifier `` `N.P` `` print alike and are two keys,
/// ordered the same way wherever they appear.
indirect enum TypeKey: Hashable, Comparable, CustomStringConvertible {
    /// A type the schema declares, by its path from the schema's name, as `["Flow", "Item"]`.
    case declared([KeyName])
    /// A standard-library type named through its module, as `Swift::Int`.
    case standard(String)
    /// A type another module declares, named through its module selector.
    case module(KeyName, KeyName)
    /// A name no declaration the macro can see has, as spelled at the schema's scope.
    case outside(KeyName)
    /// An alias the macro leaves unread, by the path of its scope and its name.
    case alias([KeyName], KeyName)
    /// A member of a type whose members the macro does not read.
    case member(TypeKey, KeyName)
    /// A member named through a module selector after a period.
    case selectedMember(TypeKey, KeyName, KeyName)
    /// A type with generic arguments.
    case generic(TypeKey, [TypeKey])
    /// A value generic argument, such as an inline array's count.
    case value(String)
    /// A tuple of other than one unlabeled element; `()` is `Void`.
    case tuple([TupleElement])
    case function(FunctionKey)
    /// A type with attributes or specifiers that are part of it, in a canonical order.
    case attributed([TypeKey], TypeKey)
    /// The metatype of a type: `.plain` for a concrete type or an existential, `.existential` for
    /// `P.Type` of a protocol `P`, which is `any P.Type`, and `.unresolved` for a base the macro cannot
    /// tell apart.
    case metatype(TypeKey, MetatypeKind)
    /// A composition, in a canonical order.
    case composition([TypeKey])
    /// An opaque `some` type, another type than its constraint.
    case opaqueResult(TypeKey)
    /// An attribute, specifier, or other syntax, keyed by its tokens and the types inside it.
    case syntax(String, [TypeKey])
    /// A reading a budget cut short, which is never equal to another and which no conclusion may rest on.
    case unresolved(Int)
    /// A type read in full whose key outgrew the key budget: its shape is known, and its identity is
    /// equal to no other.
    case distinct(Int)

    enum MetatypeKind: Int, Hashable {
        case plain
        case existential
        case unresolved
    }

    struct TupleElement: Hashable {
        let label: String?
        let type: TypeKey
        let isVariadic: Bool
    }

    struct FunctionKey: Hashable {
        struct Parameter: Hashable {
            /// The parameter's passing conventions, such as `inout` or `@escaping`, sorted.
            let conventions: [String]
            let type: TypeKey
            let isVariadic: Bool
        }

        enum Thrown: Hashable {
            case none
            case untyped
            case typed(TypeKey)
            /// A specifier other than `throws`, such as `rethrows`.
            case specifier(String)
        }

        let parameters: [Parameter]
        let isAsync: Bool
        let thrown: Thrown
        let result: TypeKey

        var description: String {
            let spelled = parameters.map { parameter in
                (parameter.conventions + [parameter.type.description]).joined(separator: " ")
                    + (parameter.isVariadic ? "..." : "")
            }
            let effects: String
            switch thrown {
            case .none: effects = ""
            case .untyped: effects = " throws"
            case .typed(let type): effects = " throws(\(type))"
            case .specifier(let text): effects = " " + text
            }
            return "(" + spelled.joined(separator: ", ") + ")" + (isAsync ? " async" : "") + effects + " -> "
                + result.description
        }
    }

    var description: String {
        switch self {
        case .declared(let path): return Self.path(path)
        case .standard(let name): return "Swift::" + name
        case .module(let module, let name): return module.text + "::" + name.text
        case .outside(let name): return name.text
        case .alias(let path, let name): return "alias " + Self.path(path + [name])
        case .member(let base, let name): return "(\(base)).\(name)"
        case .selectedMember(let base, let module, let name): return "(\(base)).\(module)::\(name)"
        case .generic(let base, let arguments): return "\(base)<\(Self.list(arguments.map(\.description)))>"
        case .value(let value): return value
        case .tuple(let elements):
            let spelled = elements.map { element in
                let label = element.label.map { $0 + ": " } ?? ""
                return label + element.type.description + (element.isVariadic ? "..." : "")
            }
            return "(" + Self.list(spelled) + ")"
        case .function(let function): return function.description
        case .attributed(let attributes, let base):
            return (attributes.map(\.description) + [base.description]).joined(separator: " ")
        case .metatype(let base, .plain): return "(\(base)).Type"
        case .metatype(let base, .existential): return "any (\(base)).Type"
        case .metatype(let base, .unresolved): return "(\(base)).Type?"
        case .composition(let elements): return elements.map(\.description).joined(separator: " & ")
        case .opaqueResult(let constraint): return "some " + constraint.description
        case .syntax(let text, let children):
            return children.isEmpty ? text : text + "[" + Self.list(children.map(\.description)) + "]"
        case .unresolved(let number): return "<unresolved \(number)>"
        case .distinct(let number): return "<distinct \(number)>"
        }
    }

    /// The keys directly inside this one.
    private var children: [TypeKey] {
        switch self {
        case .declared, .standard, .module, .outside, .alias, .value, .unresolved, .distinct: return []
        case .member(let base, _), .selectedMember(let base, _, _), .metatype(let base, _), .opaqueResult(let base):
            return [base]
        case .generic(let base, let arguments): return [base] + arguments
        case .tuple(let elements): return elements.map(\.type)
        case .function(let function):
            var keys = function.parameters.map(\.type) + [function.result]
            if case .typed(let thrown) = function.thrown { keys.append(thrown) }
            return keys
        case .attributed(let attributes, let base): return attributes + [base]
        case .composition(let elements), .syntax(_, let elements): return elements
        }
    }

    private static func list(_ items: [String]) -> String { items.joined(separator: ", ") }

    private static func path(_ names: [KeyName]) -> String { names.map(\.text).joined(separator: ".") }

    // MARK: Order

    /// Keys in a total order of their structure: by kind, then by what each kind holds, names by their
    /// numbers, so the order of two keys never depends on how either prints.
    static func < (lhs: TypeKey, rhs: TypeKey) -> Bool { order(lhs, rhs) < 0 }

    /// The position of each kind of key in the order.
    private var rank: Int {
        switch self {
        case .declared: 0
        case .standard: 1
        case .module: 2
        case .outside: 3
        case .alias: 4
        case .member: 5
        case .selectedMember: 6
        case .generic: 7
        case .value: 8
        case .tuple: 9
        case .function: 10
        case .attributed: 11
        case .metatype: 12
        case .composition: 13
        case .opaqueResult: 14
        case .syntax: 15
        case .unresolved: 16
        case .distinct: 17
        }
    }

    /// Negative, zero, or positive as `lhs` precedes, equals, or follows `rhs`.
    private static func order(_ lhs: TypeKey, _ rhs: TypeKey) -> Int {
        switch (lhs, rhs) {
        case (.declared(let a), .declared(let b)): return order(a, b, by: order)
        case (.standard(let a), .standard(let b)), (.value(let a), .value(let b)): return order(a, b)
        case (.outside(let a), .outside(let b)): return order(a, b)
        case (.module(let a, let x), .module(let b, let y)): return then(order(a, b), order(x, y))
        case (.alias(let a, let x), .alias(let b, let y)): return then(order(a, b, by: order), order(x, y))
        case (.member(let a, let x), .member(let b, let y)): return then(order(a, b), order(x, y))
        case (.selectedMember(let a, let x, let m), .selectedMember(let b, let y, let n)):
            return then(order(a, b), then(order(x, y), order(m, n)))
        case (.generic(let a, let x), .generic(let b, let y)): return then(order(a, b), order(x, y, by: order))
        case (.tuple(let a), .tuple(let b)): return order(a, b, by: order)
        case (.function(let a), .function(let b)): return order(a, b)
        case (.attributed(let a, let x), .attributed(let b, let y)): return then(order(a, b, by: order), order(x, y))
        case (.metatype(let a, let x), .metatype(let b, let y)): return then(order(a, b), x.rawValue - y.rawValue)
        case (.composition(let a), .composition(let b)): return order(a, b, by: order)
        case (.opaqueResult(let a), .opaqueResult(let b)): return order(a, b)
        case (.syntax(let a, let x), .syntax(let b, let y)): return then(order(a, b), order(x, y, by: order))
        case (.unresolved(let a), .unresolved(let b)), (.distinct(let a), .distinct(let b)): return order(a, b)
        default: return lhs.rank - rhs.rank
        }
    }

    private static func then(_ first: Int, _ second: @autoclosure () -> Int) -> Int { first != 0 ? first : second() }

    private static func order(_ lhs: String, _ rhs: String) -> Int { lhs == rhs ? 0 : lhs < rhs ? -1 : 1 }

    private static func order(_ lhs: Int, _ rhs: Int) -> Int { lhs == rhs ? 0 : lhs < rhs ? -1 : 1 }

    private static func order(_ lhs: KeyName, _ rhs: KeyName) -> Int { order(lhs.number, rhs.number) }

    private static func order(_ lhs: Bool, _ rhs: Bool) -> Int { order(lhs ? 1 : 0, rhs ? 1 : 0) }

    private static func order<Element>(_ lhs: [Element], _ rhs: [Element], by element: (Element, Element) -> Int) -> Int
    {
        for (a, b) in zip(lhs, rhs) {
            let result = element(a, b)
            if result != 0 { return result }
        }
        return order(lhs.count, rhs.count)
    }

    private static func order(_ lhs: TupleElement, _ rhs: TupleElement) -> Int {
        let labels: Int
        switch (lhs.label, rhs.label) {
        case (nil, nil): labels = 0
        case (nil, _): labels = -1
        case (_, nil): labels = 1
        case (let a?, let b?): labels = order(a, b)
        }
        return then(labels, then(order(lhs.type, rhs.type), order(lhs.isVariadic, rhs.isVariadic)))
    }

    private static func order(_ lhs: FunctionKey, _ rhs: FunctionKey) -> Int {
        let parameters = order(lhs.parameters, rhs.parameters) { a, b in
            then(
                order(a.conventions, b.conventions, by: order),
                then(order(a.type, b.type), order(a.isVariadic, b.isVariadic))
            )
        }
        return then(
            parameters,
            then(order(lhs.isAsync, rhs.isAsync), then(order(lhs.thrown, rhs.thrown), order(lhs.result, rhs.result)))
        )
    }

    private static func order(_ lhs: FunctionKey.Thrown, _ rhs: FunctionKey.Thrown) -> Int {
        switch (lhs, rhs) {
        case (.none, .none), (.untyped, .untyped): return 0
        case (.typed(let a), .typed(let b)): return order(a, b)
        case (.specifier(let a), .specifier(let b)): return order(a, b)
        default:
            func rank(_ thrown: FunctionKey.Thrown) -> Int {
                switch thrown {
                case .none: 0
                case .untyped: 1
                case .typed: 2
                case .specifier: 3
                }
            }
            return rank(lhs) - rank(rhs)
        }
    }

    // MARK: Size

    /// Whether the tree has more than `limit` nodes, counted no further than needed to tell.
    func exceeds(_ limit: Int) -> Bool {
        var remaining = limit
        return !fits(&remaining)
    }

    /// The nodes of the tree, counted no further than `limit`.
    func nodes(upTo limit: Int) -> Int {
        var remaining = limit
        return fits(&remaining) ? limit - remaining : limit
    }

    private func fits(_ remaining: inout Int) -> Bool {
        remaining -= 1
        guard remaining >= 0 else { return false }
        switch self {
        case .declared, .standard, .module, .outside, .alias, .value, .unresolved, .distinct: return true
        default: return children.allSatisfy { $0.fits(&remaining) }
        }
    }
}

/// The type declarations a schema makes visible to the macro, by scope, so an authored type spelling is
/// read for the type it names where the author wrote it.
///
/// The scopes are the schema and every nongeneric struct, enum, class, and actor declared inside it, at
/// any depth. Each holds the types and type aliases declared directly inside it; an `@Operation`
/// namespace also holds the `Input` and `Output` aliases the macro adds when it omits them, and an
/// `@Event` namespace its `Payload`. Lookup follows Swift's lexical rules over what the macro can see: a
/// name is found in the innermost scope that declares it, a generic alias's parameter inside its own
/// spelling, an alias reads as what its own spelling names where the alias is declared, with a generic
/// alias's arguments in place of its parameters, and a member is looked up in its base's scope. Names
/// are compared without backticks. Declarations outside the schema, including extensions of its types
/// and members a class inherits, are invisible.
///
/// A reading is confirmed when nothing invisible could change it: every name in it is a generic
/// parameter, `Self`, a module selector's, a type or alias found in the scope that spells it, a member
/// the macro reads of a confirmed base, the schema's own name spelled at the schema's scope, which the
/// expansion checks names the schema, or a type declared outside the schema spelled at the schema's
/// scope, whose every spelling there names one type. A name a nested scope finds in an enclosing one,
/// the schema's name among them, could be hidden by a member an extension, a superclass, or a protocol
/// extension gives the nested type, and a bare standard-library name, such as `Never` or `Error`, by a
/// declaration outside the schema, so a reading through either is unconfirmed. Its kind, which every
/// generated shape rests on, is confirmed separately: a structural spelling confirms it whatever the
/// names inside it read as, and a name only through confirmed lookups.
///
/// Reading is lazy and bounded. An alias is read only when a reading reaches it, once, and a chain of
/// aliases that each name the next, generic or not, is read without deepening the reading. An alias that
/// names a type by a path of names alone, such as `Namespace` or `Flow.Namespace`, is read where a reading
/// reaches it, so a member of it is looked up at once, as through the path itself. A generic alias reads
/// each of its arguments only where its spelling reaches that parameter, and once for every use of one
/// argument. An alias that names itself through confirmed links only is recorded in
/// ``circularAliases``; one whose cycle runs through a link the macro cannot confirm reads as an
/// unconfirmed opaque type, for the compiler to resolve. A reading whose key would grow past
/// ``keyBudget`` nodes keeps its kind with a key that stands for its identity, and a reading that takes
/// ``stepBudget`` steps, or all readings together ``totalStepBudget``, or that nests past
/// ``depthBudget`` or its thread's stack, is cut short: its `isCut` reading is never concluded from,
/// and the declaration that spells it is diagnosed.
///
/// Every unit of work a reading does is a charged step, is bounded by the syntax it reads once, or is
/// amortised against those steps: each type read, generic argument, enclosing scope a name is looked up
/// through, member a composition flattens in, node of the stack a deferred argument is read across, and
/// alias and link the cycle search inspects is a step; every name and spelling is hashed once, when it
/// is numbered, and every table a reading keeps is keyed by numbers.
struct LexicalScopes {
    /// A type alias the macro reads.
    struct Alias {
        /// The spelling it names, read in the scope that declares it.
        let target: TypeSyntax
        /// The numbers of the names of its generic parameters in order; empty for a nongeneric alias.
        let parameters: [Int]
        /// How many distinct names its parameters have, which a use must give an argument each.
        let distinctParameters: Int
        /// Whether a use's generic arguments can stand in for its parameters: each is an ordinary type
        /// parameter rather than a parameter pack or a value.
        let substitutes: Bool
        /// The declaration, for a diagnostic; `nil` for an alias the macro declares.
        let declaration: TypeAliasDeclSyntax?
    }

    /// What a scope declares under a name.
    enum Member {
        case alias(Alias)
        /// A type declaration, with the scope of its members when the macro reads them, and whether it
        /// is a protocol.
        case type(Int?, isProtocol: Bool)
    }

    struct Scope {
        /// The names of the scope's type from the schema's name: `["Flow", "Load"]`.
        let path: [KeyName]
        let parent: Int?
        /// What the scope declares, by the number of each name.
        var members: [Int: Member] = [:]
        /// The declaration of each of ``members``, by the number of its name.
        var declarations: [Int: SyntaxIdentifier] = [:]
    }

    /// The identity of an alias declaration: its scope and the number of its name.
    fileprivate struct AliasID: Hashable {
        let scope: Int
        let name: Int
    }

    /// The index of the schema's own scope.
    static let schema = 0

    /// The most nodes an alias's reading keeps as its key: an alias whose key would exceed it, as one
    /// that doubles a type at every level of a chain does, keeps the kind of type it reads as, and its
    /// key stands for its own identity, which is equal to no other spelling's.
    static let keyBudget = 1024
    /// The most steps one reading takes before it is cut short, and its declaration diagnosed.
    static let stepBudget = 100_000
    /// The most steps every reading of one schema takes together.
    static let totalStepBudget = 1_000_000
    /// The deepest one reading nests through the structure of the types it reads before it is cut short.
    ///
    /// An array of an array, or a tuple a generic alias spells, nests; a chain of aliases that each name
    /// the next does not. A reading nested deeper than ``stackCheckDepth`` is also cut short where its
    /// thread has less than ``stackMargin`` bytes of stack left.
    static let depthBudget = 1024
    static let stackCheckDepth = 16
    static let stackMargin = 160 * 1024

    let schemaName: String
    private(set) var scopes: [Scope]
    /// Every name a scope declares or a generic alias takes as a parameter, numbered once as the scopes
    /// are built, so every table a reading keeps hashes a number, and a name spelled in a reading is
    /// hashed once, where it is read.
    private var nameNumbers: [String: Int] = [:]
    private var names: [String] = []
    /// Each of `names` as keys hold it.
    private var keyNames: [KeyName] = []
    /// Every alias in declaration order, for reporting cycles in that order.
    private var order: [AliasID] = []
    private let cache = ReadingCache()

    /// The aliases found, while reading, to name themselves through links the macro confirms, in
    /// declaration order.
    var circularAliases: [TypeAliasDeclSyntax] {
        order.filter(cache.circular.contains)
            .compactMap { id in
                guard case .alias(let alias)? = scopes[id.scope].members[id.name] else { return nil }
                return alias.declaration
            }
    }

    /// Whether a reading has spent a step budget, so some alias read as opaque without being read.
    var exhaustedBudget: Bool { cache.exhausted }

    /// How many records of aliases being read the readings so far keep, for the deferred arguments that
    /// were spelled while they were read: one per alias, however many arguments share its stack.
    var retainedVisits: Int { cache.nodes.count }

    /// The work the readings so far have done, which the regression tests bound by the size of the
    /// declarations rather than by time.
    struct Work: Equatable {
        /// The steps charged to the budgets.
        var steps: Int
        /// The changes readings inside a chain logged, and those undone because the reading waited.
        var logged: Int
        var undone: Int
        /// The spelling keys computed for deferred and value arguments, and the characters of the distinct
        /// ones, each hashed once, when it is numbered.
        var spelled: Int
        var numbered: Int
        /// The arguments hashed to number the sets of arguments that generic aliases are read with.
        var hashed: Int
        /// The nodes of the stack of aliases being read that moves to and from deferred arguments walked.
        var walked: Int
        /// The members composition readings flattened into the compositions that name them.
        var flattened: Int
        /// The identifier tokens whose names were looked up, each once however many readings reach it.
        var named: Int
    }

    var work: Work {
        Work(
            steps: cache.totalSteps,
            logged: cache.loggedChanges,
            undone: cache.undoneChanges,
            spelled: cache.spelledNodes,
            numbered: cache.numberedCharacters,
            hashed: cache.hashedArguments,
            walked: cache.walkedNodes,
            flattened: cache.flattenedMembers,
            named: cache.namedTokens
        )
    }

    /// The scopes of a schema that declares nothing, for a schema built without its declaration.
    init() {
        schemaName = ""
        scopes = [Scope(path: [cache.keyName("")], parent: nil)]
    }

    init(_ declaration: EnumDeclSyntax) {
        schemaName = declaration.name.lookupName
        scopes = [Scope(path: [cache.keyName(schemaName)], parent: nil)]
        var order: [AliasID] = []
        add(declaration.memberBlock, to: Self.schema, isSchema: true, order: &order)
        self.order = order
    }

    /// The number of `name`, numbering it when it has none.
    private mutating func number(_ name: String) -> Int {
        if let number = nameNumbers[name] { return number }
        nameNumbers[name] = names.count
        names.append(name)
        keyNames.append(cache.keyName(name))
        return names.count - 1
    }

    /// The number of a name some scope declares or some generic alias takes, or `nil` for any other.
    private func number(of name: String) -> Int? { nameNumbers[name] }

    /// The number of the name an identifier token looks up, or `nil` when no scope declares it and no
    /// generic alias takes it, found once for each token however often readings reach it, so a long name
    /// is hashed once rather than at every use of the alias that spells it.
    private func number(of token: TokenSyntax) -> Int? { named(token).number }

    /// What a reading needs of the name a token spells, found once for the token.
    private func named(_ token: TokenSyntax) -> ReadingCache.Named {
        cache.named(token) { token in
            let name = token.lookupName
            let number = number(of: name)
            return ReadingCache.Named(
                token: token,
                name: name,
                key: number.map { keyNames[$0] } ?? cache.keyName(name),
                number: number,
                isSchemaName: name == schemaName,
                mayBeStandard: name.utf8.count < 32
            )
        }
    }

    private mutating func add(_ block: MemberBlockSyntax, to scope: Int, isSchema: Bool, order: inout [AliasID]) {
        for item in block.members {
            let declaration = item.decl
            if let alias = declaration.as(TypeAliasDeclSyntax.self) {
                let parameters = (alias.genericParameterClause?.parameters ?? []).map { number($0.name.lookupName) }
                let name = number(alias.name.lookupName)
                scopes[scope].declarations[name] = alias.id
                scopes[scope].members[name] = .alias(
                    Alias(
                        target: alias.initializer.value,
                        parameters: parameters,
                        distinctParameters: Set(parameters).count,
                        substitutes: (alias.genericParameterClause?.parameters ?? [])
                            .allSatisfy { $0.specifier == nil },
                        declaration: alias
                    )
                )
                order.append(AliasID(scope: scope, name: name))
                continue
            }
            if let named = declaration.as(ProtocolDeclSyntax.self) {
                let name = number(named.name.lookupName)
                scopes[scope].members[name] = .type(nil, isProtocol: true)
                scopes[scope].declarations[name] = named.id
                continue
            }
            let nominal: (name: String, generic: Bool, block: MemberBlockSyntax, attributes: AttributeListSyntax)?
            if let type = declaration.as(StructDeclSyntax.self) {
                nominal = (type.name.lookupName, type.genericParameterClause != nil, type.memberBlock, type.attributes)
            } else if let type = declaration.as(EnumDeclSyntax.self) {
                nominal = (type.name.lookupName, type.genericParameterClause != nil, type.memberBlock, type.attributes)
            } else if let type = declaration.as(ClassDeclSyntax.self) {
                nominal = (type.name.lookupName, type.genericParameterClause != nil, type.memberBlock, type.attributes)
            } else if let type = declaration.as(ActorDeclSyntax.self) {
                nominal = (type.name.lookupName, type.genericParameterClause != nil, type.memberBlock, type.attributes)
            } else {
                nominal = nil
            }
            guard let nominal else { continue }
            scopes[scope].declarations[number(nominal.name)] = declaration.id
            // A generic type's members depend on its arguments, so a member of it stays unread.
            guard !nominal.generic else {
                scopes[scope].members[number(nominal.name)] = .type(nil, isProtocol: false)
                continue
            }
            let child = scopes.count
            let name = number(nominal.name)
            scopes.append(Scope(path: scopes[scope].path + [keyNames[name]], parent: scope))
            scopes[scope].members[name] = .type(child, isProtocol: false)
            add(nominal.block, to: child, isSchema: false, order: &order)
            guard isSchema else { continue }
            // The macro declares the aliases a namespace omits as `Void`.
            let marks = { (name: String) in
                nominal.attributes.contains { $0.as(AttributeSyntax.self).map { Schema.namesMacro($0, name) } ?? false }
            }
            let defaults = marks("Operation") ? ["Input", "Output"] : marks("Event") ? ["Payload"] : []
            for name in defaults.map({ number($0) }) where scopes[child].members[name] == nil {
                scopes[child].members[name] = .alias(
                    Alias(
                        target: TypeSyntax(stringLiteral: "Swift::Void"),
                        parameters: [],
                        distinctParameters: 0,
                        substitutes: true,
                        declaration: nil
                    )
                )
                order.append(AliasID(scope: child, name: name))
            }
        }
    }

    /// The spelling of the alias that scope `scope` declares under `name`, when the author declared it.
    func declaredAlias(_ name: String, in scope: Int) -> TypeSyntax? {
        guard scopes.indices.contains(scope), let name = number(of: name),
            case .alias(let alias)? = scopes[scope].members[name], alias.declaration != nil
        else { return nil }
        return alias.target
    }

    /// The scope of the type the schema declares directly under `name`, when the macro reads its members.
    func memberScope(_ name: String) -> Int? {
        guard let name = number(of: name), case .type(let scope, _)? = scopes[Self.schema].members[name]
        else {
            return nil
        }
        return scope
    }

    /// The declarations of the schema that `type`, spelled in `scope`, names.
    ///
    /// They are each type reference resolved by lookup from `scope` outward, and each member of a type
    /// whose members the macro reads, such as `Notes.Draft`, found in that type. A name declared nowhere
    /// the macro reads, such as one outside the schema, names none of them, and an alias's own spelling
    /// is the alias's to resolve.
    func namedDeclarations(_ type: TypeSyntax, in scope: Int = Self.schema) -> [SyntaxIdentifier] {
        let scope = scopes.indices.contains(scope) ? scope : Self.schema
        var result: [SyntaxIdentifier] = []
        /// The scope whose members a reference names, when the macro reads them.
        func members(of type: TypeSyntax) -> Int? {
            let type = type.unparenthesized
            if let identifier = type.as(IdentifierTypeSyntax.self) {
                guard identifier.moduleSelector == nil, identifier.genericArgumentClause == nil else { return nil }
                if identifier.name.tokenKind == .keyword(.Self) { return scope }
                guard case .identifier = identifier.name.tokenKind else { return nil }
                guard let name = number(of: identifier.name), case .found(let index) = lookup(name, from: scope)
                else {
                    // The schema's own name, which no member may take, names the schema.
                    return identifier.name.lookupName == schemaName ? Self.schema : nil
                }
                guard case .type(let child, _)? = scopes[index].members[name] else { return nil }
                return child
            }
            guard let member = type.as(MemberTypeSyntax.self), member.moduleSelector == nil,
                member.genericArgumentClause == nil, let base = members(of: member.baseType),
                let name = number(of: member.name), case .type(let child, _)? = scopes[base].members[name]
            else { return nil }
            return child
        }
        var pending = [Syntax(type)]
        while let node = pending.popLast() {
            pending += node.children(viewMode: .sourceAccurate).reversed()
            if let identifier = node.as(IdentifierTypeSyntax.self), identifier.moduleSelector == nil,
                case .identifier = identifier.name.tokenKind, let name = number(of: identifier.name),
                case .found(let index) = lookup(name, from: scope),
                let declaration = scopes[index].declarations[name]
            {
                result.append(declaration)
            } else if let member = node.as(MemberTypeSyntax.self), member.moduleSelector == nil,
                let base = members(of: member.baseType), let name = number(of: member.name),
                let declaration = scopes[base].declarations[name]
            {
                result.append(declaration)
            }
        }
        return result
    }

    /// Reads `type` as the declarations visible from `scope` resolve it.
    ///
    /// A passing convention of the spelling itself, such as `sending` or `@escaping` on a parameter,
    /// leaves the type it names unchanged.
    func resolve(_ type: TypeSyntax, in scope: Int = Self.schema) -> ResolvedType {
        let scope = scopes.indices.contains(scope) ? scope : Self.schema
        let key = ReadingCache.ResultKey(spelling: Schema.spellingKey(type), scope: scope)
        if let cached = cache.results[key] { return cached }
        cache.readingSteps = 0
        let result: ResolvedType
        if let attributed = type.as(AttributedTypeSyntax.self) {
            result = attributedReference(attributed, scope, .none, keepsConventions: false).resolved
        } else {
            result = reference(type, scope, .none).resolved
        }
        assert(result.countsItsKey, "\(result.size) nodes counted for \(result.key)")
        cache.results[key] = result
        return result
    }

    /// Reads a spelling as the declarations visible from `scope` resolve it.
    func resolve(_ spelling: String, in scope: Int = Self.schema) -> ResolvedType {
        resolve(TypeSyntax(stringLiteral: spelling), in: scope)
    }

    // MARK: Types

    /// How a reference's metatype is formed, which depends on how its name reached the type.
    fileprivate enum Form {
        /// A concrete type, whose `.Type` is its metatype.
        case concrete
        /// A protocol or composition named as one, whose `.Type` is the existential `any P.Type`, or a
        /// name of a type that is either that or concrete.
        case bare
        /// An existential named with `any`, or a generic argument in place of a parameter, whose `.Type`
        /// is the metatype of that value's type.
        case value
        /// A name the macro cannot see into, which may be an alias of any of them.
        case unknown

        /// The form a type has once it stands in for a generic parameter.
        var substituted: Form {
            switch self {
            case .concrete: .concrete
            case .bare, .value, .unknown: .value
            }
        }
    }

    /// What the readings folded into one say about it: whether every one is confirmed, and whether a
    /// budget cut any of them short.
    fileprivate struct Evidence {
        var confirmed = true
        var cut = false
        /// The nodes of the keys folded in, counted no further than one past ``keyBudget``.
        var size = 0

        init() {}

        init(_ readings: [ResolvedType]) {
            for reading in readings { add(reading) }
        }

        mutating func add(_ reading: ResolvedType) {
            confirmed = confirmed && reading.isConfirmed
            cut = cut || reading.isCut
            size = ResolvedType.counted(size + reading.size)
        }
    }

    /// A type reference read through the visible declarations: what it resolves to, the scope of its
    /// members when it names a type whose members the macro reads, and how its metatype is formed.
    fileprivate struct Reference {
        var resolved: ResolvedType
        var scope: Int?
        /// The module a free base names, such as `Swift` in `Swift.Int`, which no visible declaration hides.
        var module: String?
        var form: Form
        /// The number of the kept reading of an alias or a generic alias's use that this one is, by
        /// whatever spelling reached it, so a composition that names it again need not flatten it again.
        var identity: Int?

        init(_ resolved: ResolvedType, scope: Int? = nil, module: String? = nil, form: Form) {
            self.resolved = resolved
            self.scope = scope
            self.module = module
            self.form = form
        }

        /// A reference to a type the macro cannot see into, keyed `key`, whose nodes are those of
        /// `evidence` and `nodes` more.
        static func opaque(_ key: TypeKey, _ evidence: Evidence = Evidence(), nodes: Int = 1) -> Reference {
            Reference(ResolvedType(key: key, reading: .opaque, evidence: evidence, nodes: nodes), form: .unknown)
        }

        /// The same reference, confirmed only when it was and `confirmed` holds, in its identity and its
        /// shape alike: a lookup the macro cannot confirm could find another type of any kind.
        func confirmed(_ confirmed: Bool) -> Reference {
            guard !confirmed else { return self }
            var copy = self
            copy.resolved.isConfirmed = false
            copy.resolved.isShapeConfirmed = false
            return copy
        }
    }

    /// The arguments of the generic alias being read, by parameter name, each a deferred argument.
    ///
    /// Each set of arguments is interned once, when its alias is expanded, so a deferred argument spelled
    /// inside the expansion is keyed by the set's number rather than by every argument it holds.
    fileprivate struct Bindings {
        let id: Int
        /// The deferred argument of each parameter, by the number of its name.
        let arguments: [Int: Int]

        /// The arguments outside every generic alias: none.
        static let none = Bindings(id: 0, arguments: [:])

        subscript(name: Int) -> Int? { arguments[name] }
    }

    /// What reading a reference by name comes to: a reading, a generic alias to expand in its place, or a
    /// deferred argument to read in its place, which ``reference(_:_:_:)`` reads in the same frame, so a
    /// chain of generic aliases that each name the next, or pass on an argument, reads without
    /// deepening the stack.
    fileprivate indirect enum Step {
        case done(Reference)
        case expand(Tail, target: TypeSyntax, scope: Int, bindings: Bindings)
        case argument(Int)
    }

    /// What finishes a reading read in place: an expanded generic alias, or a deferred argument with
    /// the aliases being read where it was reached.
    fileprivate enum Frame {
        case alias(Tail)
        case argument(Int, restoring: ReadingCache.Position)
    }

    /// What finishes the reading of one generic alias expanded in place: its memo, the confirmation of
    /// the lookup that found it, and its place among the aliases being read.
    fileprivate struct Tail {
        let expansion: ReadingCache.ExpansionKey
        let confirmed: Bool
        let visit: ReadingCache.Visit
    }

    /// Reads a type of any kind; `bindings` holds the arguments of the generic alias being read.
    ///
    /// Every kind of type has a reading. Sugar keys as the type it abbreviates, so `[T]` and
    /// `Swift::Array<T>` share a key, and a kind the macro cannot judge reads as opaque, which the
    /// expansion checks where it matters. A generic alias whose use this reading reaches is expanded in
    /// this frame, so a chain of them reads iteratively; each other kind is read by a function of its
    /// own, so a reading nested through structure deepens the stack by small frames. A reading nested
    /// deeper than ``depthBudget``, or than its thread's stack allows, is cut short.
    private func reference(_ type: TypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        let step = dispatch(type, scope, bindings)
        guard case .done(let reference) = step else { return chain(from: step) }
        return reference
    }

    /// Reads one type, or says which alias or argument to read in its place.
    private func dispatch(_ type: TypeSyntax, _ scope: Int, _ bindings: Bindings) -> Step {
        // Every step is charged here and checked against the budgets as it is charged, so no structure,
        // however wide, reads past them.
        cache.step()
        guard cache.canRead, cache.depth < Self.depthBudget,
            cache.depth < Self.stackCheckDepth || Self.hasStackRoom()
        else {
            return .done(cache.unresolved())
        }
        cache.depth += 1
        defer { cache.depth -= 1 }
        switch type.kind {
        case .identifierType: return identifierReference(type.cast(IdentifierTypeSyntax.self), scope, bindings)
        case .memberType: return memberReference(type.cast(MemberTypeSyntax.self), scope, bindings)
        default: return .done(structuralReference(type, scope, bindings))
        }
    }

    /// Reads, in one frame, each alias or argument a reading names in its place, then finishes them in
    /// reverse: each expansion is kept for its use, and each argument for its parameter.
    private func chain(from first: Step) -> Reference {
        var frames: [Frame] = []
        var step = first
        var result: Reference
        while true {
            switch step {
            case .done(let reference):
                result = reference
            case .expand(let tail, let target, let scope, let bindings):
                frames.append(.alias(tail))
                cache.push(tail.visit)
                step = dispatch(target, scope, bindings)
                continue
            case .argument(let index):
                if let value = cache.thunks[index].value {
                    result = value
                    break
                }
                frames.append(.argument(index, restoring: cache.enter(index)))
                let thunk = cache.thunks[index]
                step = dispatch(thunk.type, thunk.scope, thunk.bindings)
                continue
            }
            break
        }
        while let frame = frames.popLast() {
            switch frame {
            case .alias(let tail):
                cache.pop()
                result = cache.keep(result, for: tail.expansion).confirmed(tail.confirmed)
            case .argument(let index, let saved):
                result = cache.leave(index, restoring: saved, with: result)
            }
        }
        return result
    }

    /// Whether the current thread has more than ``stackMargin`` bytes of stack left below this frame,
    /// where the platform reports its stack; elsewhere ``depthBudget`` alone bounds the nesting.
    private static func hasStackRoom() -> Bool {
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        guard top > size, here <= top else { return true }
        return here > top - size + UInt(stackMargin)
        #else
        return true
        #endif
    }

    /// Reads a type other than a reference by name.
    private func structuralReference(_ type: TypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        switch type.kind {
        case .tupleType: return tupleReference(type.cast(TupleTypeSyntax.self), scope, bindings)
        case .arrayType, .dictionaryType, .optionalType, .implicitlyUnwrappedOptionalType:
            return sugarReference(type, scope, bindings)
        case .inlineArrayType: return inlineArrayReference(type.cast(InlineArrayTypeSyntax.self), scope, bindings)
        case .attributedType:
            return attributedReference(type.cast(AttributedTypeSyntax.self), scope, bindings, keepsConventions: true)
        case .someOrAnyType: return existentialReference(type.cast(SomeOrAnyTypeSyntax.self), scope, bindings)
        case .compositionType: return compositionReference(type.cast(CompositionTypeSyntax.self), scope, bindings)
        case .functionType: return functionReference(type.cast(FunctionTypeSyntax.self), scope, bindings)
        case .metatypeType: return metatypeReference(type.cast(MetatypeTypeSyntax.self), scope, bindings)
        // Each has values, or is meaningful only in a generic signature the compiler checks.
        case .packElementType, .packExpansionType, .suppressedType, .classRestrictionType:
            return syntaxReference(type, .visible, scope, bindings)
        default: return syntaxReference(type, .opaque, scope, bindings)
        }
    }

    /// Reads an array, a dictionary, or an optional spelled with sugar, which always names the
    /// standard library's type.
    private func sugarReference(_ type: TypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        if let array = type.as(ArrayTypeSyntax.self) { return standard("Array", [array.element], scope, bindings) }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return standard("Dictionary", [dictionary.key, dictionary.value], scope, bindings)
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return standard("Optional", [optional.wrappedType], scope, bindings)
        }
        // An implicitly unwrapped optional has the type `Optional`.
        let optional = type.cast(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        return standard("Optional", [optional.wrappedType], scope, bindings)
    }

    private func tupleReference(_ tuple: TupleTypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        if tuple.elements.isEmpty { return Reference(ResolvedType(key: .tuple([]), reading: .void), form: .concrete) }
        if let only = Self.parenthesized(tuple) {
            // Parentheses keep what a type names, its members, and its metatype, but no module.
            var inner = reference(only, scope, bindings)
            inner.module = nil
            return inner
        }
        var evidence = Evidence()
        var elements: [TypeKey.TupleElement] = []
        for element in tuple.elements {
            let reading = reference(element.type, scope, bindings).resolved
            evidence.add(reading)
            elements.append(
                TypeKey.TupleElement(
                    label: element.firstName.flatMap(Self.tupleLabel),
                    type: reading.key,
                    isVariadic: element.ellipsis != nil
                )
            )
            // A reading cut short decides nothing, so the elements after it are left unread.
            if reading.isCut { break }
        }
        return Reference(ResolvedType(key: .tuple(elements), reading: .visible, evidence: evidence), form: .concrete)
    }

    private func inlineArrayReference(
        _ array: InlineArrayTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let readings = [argument(array.count, scope, bindings), argument(array.element, scope, bindings)]
        return Reference(
            ResolvedType(
                key: .generic(.standard("InlineArray"), readings.map(\.key)),
                reading: .visible,
                evidence: Evidence(readings),
                nodes: 2
            ),
            form: .concrete
        )
    }

    private func existentialReference(
        _ existential: SomeOrAnyTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let constraint = reference(existential.constraint, scope, bindings)
        guard existential.someOrAnySpecifier.tokenKind == .keyword(.any) else {
            // An opaque `some` type is another type than its constraint.
            return Reference(
                ResolvedType(
                    key: .opaqueResult(constraint.resolved.key),
                    reading: .visible,
                    evidence: Evidence([constraint.resolved])
                ),
                form: .concrete
            )
        }
        // `any P` names the existential that a bare `P` names, as `any P.Type` names `P.Type`, but its
        // metatype is the metatype of that existential.
        return Reference(constraint.resolved, form: .value)
    }

    /// Reads a composition, which names the same type in any order, with a composition inside it
    /// flattened into it and each member once, so `PQ & R` for `PQ = P & Q`, `P & Q & R`, and
    /// `R & Q & P & P` share a key, and one with a single member names that member.
    ///
    /// Each member flattened in is charged a step, and a composition kept as an alias's reading is
    /// flattened once however often, and by whatever spelling, the composition names it, so the members
    /// gathered grow with the distinct members, not with the occurrences.
    private func compositionReference(
        _ composition: CompositionTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        var evidence = Evidence()
        var members: [TypeKey] = []
        var gathered: Set<TypeKey> = []
        var flattened: Set<Int> = []
        var readings: [Reference] = []
        // The nodes of the members gathered, each counted once, as the key keeps each once.
        var nodes = 1
        elements: for element in composition.elements {
            let reading = reference(element.type, scope, bindings)
            evidence.add(reading.resolved)
            readings.append(reading)
            if reading.resolved.isCut { break }
            guard case .composition(let inner) = reading.resolved.key else {
                if gathered.insert(reading.resolved.key).inserted {
                    members.append(reading.resolved.key)
                    nodes = ResolvedType.counted(nodes + reading.resolved.size)
                }
                continue
            }
            if let identity = reading.identity, !flattened.insert(identity).inserted { continue }
            for member in inner {
                cache.step(flattening: 1)
                guard cache.canRead else {
                    evidence.cut = true
                    break elements
                }
                // A member is counted no further than the budget, in the walk its hash already takes.
                if gathered.insert(member).inserted {
                    members.append(member)
                    nodes = ResolvedType.counted(nodes + member.nodes(upTo: LexicalScopes.keyBudget + 1))
                }
            }
        }
        // Members are ordered by their structure, so equal compositions in any order have one key.
        let keys = members.sorted()
        if keys.count == 1, var only = readings.first(where: { $0.resolved.key == keys[0] }) {
            only.scope = nil
            only.module = nil
            only.resolved.isConfirmed = evidence.confirmed
            only.resolved.isCut = evidence.cut
            return only
        }
        var resolved = ResolvedType(key: .composition(keys), reading: .visible, evidence: evidence)
        resolved.size = nodes
        return Reference(resolved, form: .bare)
    }

    private func functionReference(_ function: FunctionTypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        let (key, evidence, size) = functionKey(function, scope, bindings)
        var resolved = ResolvedType(key: .function(key), reading: .visible, isFunction: true, evidence: evidence)
        resolved.size = size
        return Reference(resolved, form: .concrete)
    }

    private func metatypeReference(_ metatype: MetatypeTypeSyntax, _ scope: Int, _ bindings: Bindings) -> Reference {
        let base = reference(metatype.baseType, scope, bindings)
        let kind: TypeKey.MetatypeKind
        let form: Form
        if metatype.metatypeSpecifier.tokenKind == .keyword(.Protocol) {
            // `P.Protocol` is the metatype of the existential `any P`.
            (kind, form) = (.plain, .concrete)
        } else {
            switch base.form {
            case .concrete, .value: (kind, form) = (.plain, .concrete)
            // `P.Type` of a protocol is the existential of its conforming types' metatypes, and so is
            // `P.Type.Type`.
            case .bare: (kind, form) = (.existential, .bare)
            case .unknown: (kind, form) = (.unresolved, .unknown)
            }
        }
        return Reference(
            ResolvedType(
                key: .metatype(base.resolved.key, kind),
                reading: .visible,
                evidence: Evidence([base.resolved])
            ),
            form: form
        )
    }

    private func syntaxReference(
        _ type: TypeSyntax,
        _ reading: ResolvedType.Reading,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let (key, evidence) = syntaxKey(Syntax(type), scope, bindings)
        return Reference(
            ResolvedType(key: key, reading: reading, evidence: evidence),
            form: reading == .opaque ? .unknown : .concrete
        )
    }

    /// The single unlabeled element of a parenthesized type, as in `(Values)` or `(_: Values)`, or `nil`
    /// for a tuple.
    static func parenthesized(_ tuple: TupleTypeSyntax) -> TypeSyntax? {
        guard tuple.elements.count == 1, let only = tuple.elements.first,
            only.firstName.flatMap(tupleLabel) == nil, only.secondName == nil, only.ellipsis == nil,
            only.inoutKeyword == nil
        else { return nil }
        return only.type
    }

    /// The label a tuple element's name gives it, or `nil` for none.
    ///
    /// The wildcard `_` is no label, as Swift reads it, so `(_: A, B)` is `(A, B)` and `(_: A)` is `A`.
    /// Any other name is its label without backticks that change nothing, and a backticked `` `_` `` is a
    /// label of its own, kept distinct from every name.
    static func tupleLabel(_ name: TokenSyntax) -> String? {
        if name.tokenKind == .wildcard { return nil }
        guard case .identifier = name.tokenKind, let identifier = name.identifier?.name else { return name.text }
        return identifier == "_" ? "`_`" : identifier
    }

    /// A standard-library generic type spelled with sugar, which always names the standard library's
    /// type, keyed through its module.
    private func standard(
        _ name: String,
        _ arguments: [TypeSyntax],
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let readings = arguments.map { reference($0, scope, bindings).resolved }
        return Reference(
            ResolvedType(
                key: .generic(.standard(name), readings.map(\.key)),
                reading: .visible,
                evidence: Evidence(readings),
                nodes: 2
            ),
            form: .concrete
        )
    }

    /// The standard-library names the macro reads bare, or through a `Swift` the schema does not
    /// declare, as the standard library's own wherever no visible declaration hides them: the ones
    /// sugar and module selectors also spell, and `Error`, which a throws clause spells.
    ///
    /// Another declaration outside the schema could take any of them, so a reading through one is
    /// unconfirmed. Every other name declared outside the schema reads as opaque.
    private static let standardNames: Set<String> = ["Array", "Dictionary", "Optional", "InlineArray", "Error"]

    /// The standard library's generic types that sugar also spells, which are concrete, so
    /// `Swift::Array<T>.Type` is the metatype that `[T].Type` is.
    private static let sugaredNames: Set<String> = ["Array", "Dictionary", "Optional", "InlineArray"]

    /// The attributes that only say how a parameter is passed, which leave its type unchanged.
    static let parameterAttributes: Set<String> = ["escaping", "autoclosure", "noescape"]
    /// The specifiers that only say how a parameter is passed, which leave its type unchanged.
    static let parameterSpecifiers: Set<String> = ["inout", "borrowing", "consuming", "__owned", "__shared", "sending"]

    /// The passing conventions an attributed type spells, sorted, and whether `element` is one.
    private static func isConvention(_ element: AttributeListSyntax.Element) -> Bool {
        guard case .attribute(let attribute) = element else { return false }
        return parameterAttributes.contains(attribute.attributeName.trimmedDescription)
    }

    private static func isConvention(_ specifier: TypeSpecifierListSyntax.Element) -> Bool {
        guard case .simpleTypeSpecifier(let simple) = specifier else { return false }
        return parameterSpecifiers.contains(simple.specifier.text)
    }

    /// Whether an attribute's name names a type, as a custom attribute such as a global actor does,
    /// bare, through a module, or as a member such as `Actors.Main`, rather than one the compiler defines.
    private static func namesType(_ name: TypeSyntax) -> Bool {
        guard let identifier = name.as(IdentifierTypeSyntax.self) else { return name.is(MemberTypeSyntax.self) }
        return identifier.moduleSelector != nil || !TypeQualifier.builtInAttributes.contains(identifier.name.lookupName)
    }

    /// The passing conventions an attributed parameter type spells, sorted.
    private static func conventions(_ attributed: AttributedTypeSyntax) -> [String] {
        let specifiers = (Array(attributed.specifiers) + Array(attributed.lateSpecifiers)).filter(isConvention)
            .map(\.trimmedDescription)
        let attributes = attributed.attributes.filter(isConvention).map(\.trimmedDescription)
        return (specifiers + attributes).sorted()
    }

    /// Reads an attributed type: every attribute or specifier other than a passing convention is part
    /// of the type, in any order, and a passing convention is part of it too unless `keepsConventions`
    /// is false, as it is for the spelling of a parameter itself.
    private func attributedReference(
        _ attributed: AttributedTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings,
        keepsConventions: Bool
    ) -> Reference {
        let base = reference(attributed.baseType, scope, bindings)
        var evidence = Evidence([base.resolved])
        var keys: [TypeKey] = []
        for specifier in Array(attributed.specifiers) + Array(attributed.lateSpecifiers)
        where keepsConventions || !Self.isConvention(specifier) {
            keys.append(.syntax(Schema.spellingKey(specifier), []))
        }
        for element in attributed.attributes where keepsConventions || !Self.isConvention(element) {
            guard case .attribute(let attribute) = element, Self.namesType(attribute.attributeName) else {
                keys.append(.syntax(Schema.spellingKey(element), []))
                continue
            }
            // A custom attribute, such as a global actor, names a type, read as any type reference is.
            let actor = reference(attribute.attributeName, scope, bindings).resolved
            evidence.add(actor)
            let arguments = attribute.arguments.map { Schema.spellingKey(Syntax($0)) } ?? ""
            keys.append(.syntax("@" + arguments, [actor.key]))
        }
        guard !keys.isEmpty else {
            var plain = base
            plain.scope = nil
            plain.module = nil
            return plain
        }
        // An attribute leaves the kind of type its base is, which only the base's reading confirms.
        var attributed = ResolvedType(
            key: .attributed(keys.sorted(), base.resolved.key),
            reading: .visible,
            isFunction: base.resolved.isFunction,
            evidence: evidence,
            nodes: 1 + keys.count
        )
        attributed.isShapeConfirmed = base.resolved.confirmsShape
        return Reference(attributed, form: .concrete)
    }

    /// The key of a function type: its parameters with their passing conventions, which are part of the
    /// function's type, its effects, with a throw of `Never` read as none and a throw of `any Error` as
    /// an untyped one, and its result; and what its readings say about it.
    private func functionKey(
        _ function: FunctionTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> (key: TypeKey.FunctionKey, evidence: Evidence, size: Int) {
        var evidence = Evidence()
        // The function's own node, and those of its parameters, its result, and a typed throw.
        var size = 1
        var parameters: [TypeKey.FunctionKey.Parameter] = []
        for element in function.parameters {
            var conventions: [String] = element.inoutKeyword.map { _ in ["inout"] } ?? []
            let reading: ResolvedType
            if let attributed = element.type.as(AttributedTypeSyntax.self) {
                conventions += Self.conventions(attributed)
                reading = attributedReference(attributed, scope, bindings, keepsConventions: false).resolved
            } else {
                reading = reference(element.type, scope, bindings).resolved
            }
            evidence.add(reading)
            size = ResolvedType.counted(size + reading.size)
            parameters.append(
                TypeKey.FunctionKey.Parameter(
                    conventions: conventions.sorted(),
                    type: reading.key,
                    isVariadic: element.ellipsis != nil
                )
            )
            if reading.isCut { break }
        }
        let isAsync = function.effectSpecifiers?.asyncSpecifier != nil
        // A reading cut short decides nothing, so the rest of the function is left unread.
        guard !evidence.cut else {
            return (
                TypeKey.FunctionKey(parameters: parameters, isAsync: isAsync, thrown: .none, result: .tuple([])),
                evidence,
                ResolvedType.counted(size + 1)
            )
        }
        var thrown = TypeKey.FunctionKey.Thrown.none
        if let throwsClause = function.effectSpecifiers?.throwsClause {
            if let type = throwsClause.type {
                let reading = reference(type, scope, bindings).resolved
                evidence.add(reading)
                if reading.key == .standard("Error") {
                    thrown = .untyped
                } else if !reading.isNever {
                    thrown = .typed(reading.key)
                    size = ResolvedType.counted(size + reading.size)
                }
            } else {
                thrown =
                    throwsClause.throwsSpecifier.tokenKind == .keyword(.throws)
                    ? .untyped : .specifier(throwsClause.throwsSpecifier.text)
            }
        }
        let result = reference(function.returnClause.type, scope, bindings).resolved
        evidence.add(result)
        return (
            TypeKey.FunctionKey(
                parameters: parameters,
                isAsync: isAsync,
                thrown: thrown,
                result: result.key
            ),
            evidence,
            ResolvedType.counted(size + result.size)
        )
    }

    /// The key of a node read token by token, with each type inside it read as `resolve(_:in:)` reads it,
    /// and what those readings say about it.
    private func syntaxKey(
        _ node: Syntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> (key: TypeKey, evidence: Evidence) {
        var evidence = Evidence()
        var tokens: [String] = []
        var children: [TypeKey] = []
        for child in node.children(viewMode: .sourceAccurate) {
            if let token = child.as(TokenSyntax.self) {
                if token.presence == .present { tokens.append(token.lookupName) }
            } else if let type = child.as(TypeSyntax.self) {
                let reading = reference(type, scope, bindings).resolved
                evidence.add(reading)
                tokens.append("_")
                children.append(reading.key)
            } else {
                let inner = syntaxKey(child, scope, bindings)
                evidence.confirmed = evidence.confirmed && inner.evidence.confirmed
                evidence.cut = evidence.cut || inner.evidence.cut
                evidence.size = ResolvedType.counted(evidence.size + 1 + inner.evidence.size)
                tokens.append("_")
                children.append(inner.key)
            }
            if evidence.cut { break }
        }
        return (.syntax(tokens.joined(separator: " "), children), evidence)
    }

    // MARK: References

    /// One generic argument of a use, read lazily: a type, by the deferred reading that reads it, or a
    /// value.
    fileprivate enum Argument: Hashable {
        case type(Int)
        /// A value, by the number of its spelling.
        case value(Int)
    }

    /// Reads every generic argument of a use: the key it adds to the use and what the readings say.
    private func readArguments(
        _ clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings
    ) -> (keys: [TypeKey], evidence: Evidence) {
        guard let clause else { return ([], Evidence()) }
        var readings: [ResolvedType] = []
        for element in clause.arguments {
            readings.append(argument(element, scope, bindings))
            if readings.last?.isCut == true { break }
        }
        return (readings.map(\.key), Evidence(readings))
    }

    private func argument(_ argument: GenericArgumentSyntax, _ scope: Int, _ bindings: Bindings) -> ResolvedType {
        switch argument.argument {
        case .type(let type): return reference(type, scope, bindings).resolved
        case .expr(let expression):
            // A value is charged as a type is, and keyed by its spelling, computed once however often it is read.
            cache.step()
            guard cache.canRead else { return cache.unresolved().resolved }
            return ResolvedType(key: .value(cache.spelling(of: Syntax(expression)).text), reading: .visible)
        }
    }

    /// The nodes a key that `specialized(_:_:_:)` builds has besides its arguments' and its base's
    /// readings: its base's own node, and a generic node when the use has arguments.
    private static func specializedNodes(_ clause: GenericArgumentClauseSyntax?) -> Int { clause == nil ? 1 : 2 }

    /// A key with the generic arguments of a use, when it has any.
    private static func specialized(
        _ base: TypeKey,
        _ arguments: [TypeKey],
        _ clause: GenericArgumentClauseSyntax?
    ) -> TypeKey {
        clause == nil ? base : .generic(base, arguments)
    }

    /// Reads a type named by an identifier.
    ///
    /// It only dispatches, so a reading nested through it keeps a small frame; each outcome is read by
    /// a function of its own, and a generic alias is left for the caller to expand.
    private func identifierReference(
        _ identifier: IdentifierTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Step {
        guard identifier.moduleSelector == nil, case .identifier = identifier.name.tokenKind else {
            return .done(keywordOrSelectedReference(identifier, scope, bindings))
        }
        // A name no scope declares and no generic alias takes is found nowhere.
        guard let name = number(of: identifier.name) else {
            return .done(unfoundReference(identifier, scope, bindings))
        }
        // A generic alias's parameter, inside the alias's own spelling, names its argument.
        if let bound = bindings[name] {
            guard identifier.genericArgumentClause == nil else {
                return .done(boundReference(bound, identifier, scope, bindings))
            }
            return .argument(bound)
        }
        let index: Int
        switch lookup(name, from: scope) {
        case .found(let found): index = found
        case .absent: return .done(unfoundReference(identifier, scope, bindings))
        case .cut: return .done(cache.unresolved())
        }
        // A member an extension, a superclass, or a protocol extension gives the scope that spells the
        // name would hide what an enclosing scope declares.
        return read(
            name,
            in: index,
            clause: identifier.genericArgumentClause,
            scope,
            bindings,
            confirmed: index == scope
        )
    }

    private enum Lookup {
        case found(Int)
        case absent
        /// The budget ran out before the lookup finished.
        case cut
    }

    /// The innermost scope, from `scope` outward, that declares `name`.
    ///
    /// Each enclosing scope it moves out to is charged a step and checked against the budgets, so a
    /// name read in a deeply nested scope spends the budget in proportion to the scopes it passes.
    private func lookup(_ name: Int, from scope: Int) -> Lookup {
        var index = scope
        while true {
            if scopes[index].members[name] != nil { return .found(index) }
            guard let parent = scopes[index].parent else { return .absent }
            cache.step()
            guard cache.canRead else { return .cut }
            index = parent
        }
    }

    /// Reads a module selector's type, `Self`, `Any`, or a placeholder such as `_`.
    private func keywordOrSelectedReference(
        _ identifier: IdentifierTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let clause = identifier.genericArgumentClause
        if let selector = identifier.moduleSelector {
            let named = self.named(identifier.name)
            let name = named.name
            let moduleNamed = self.named(selector.moduleName)
            let module = moduleNamed.name
            let isSwift = module == "Swift"
            if isSwift, clause == nil, named.mayBeStandard, let standard = ResolvedType.standard(name) {
                return Reference(standard, form: .concrete)
            }
            let arguments = readArguments(clause, scope, bindings)
            let base: TypeKey = isSwift ? .standard(name) : .module(moduleNamed.key, named.key)
            // A module selector names one declaration, but only a standard-library declaration whose kind
            // the macro knows confirms that kind: another standard name, or another module's, may be an
            // alias of a function type, of `Void`, or of `Never`.
            let known = isSwift && named.mayBeStandard && ResolvedType.standardValueTypes.contains(name)
            return Reference(
                ResolvedType(
                    key: Self.specialized(base, arguments.keys, clause),
                    reading: known ? .visible : .opaque,
                    evidence: arguments.evidence,
                    nodes: Self.specializedNodes(clause)
                ),
                form: isSwift && named.mayBeStandard && Self.sugaredNames.contains(name) ? .concrete : .unknown
            )
        }
        switch identifier.name.tokenKind {
        case .keyword(.Self):
            return Reference(ResolvedType(key: key(of: scope), reading: .visible), scope: scope, form: .concrete)
        case .keyword(.Any):
            return Reference(ResolvedType(key: .standard("Any"), reading: .visible), form: .bare)
        default:
            // A placeholder such as `_` names nothing the macro can read.
            let arguments = readArguments(clause, scope, bindings)
            return .opaque(.syntax(identifier.name.text, arguments.keys), arguments.evidence)
        }
    }

    /// Reads a generic alias's parameter given generic arguments, which only the compiler can judge.
    private func boundReference(
        _ bound: Int,
        _ identifier: IdentifierTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let value = force(bound)
        let arguments = readArguments(identifier.genericArgumentClause, scope, bindings)
        var evidence = arguments.evidence
        evidence.add(value.resolved)
        return .opaque(.generic(value.resolved.key, arguments.keys), evidence)
    }

    /// Reads a name no visible scope declares: the schema's own, a standard-library one, or one
    /// declared outside the schema.
    private func unfoundReference(
        _ identifier: IdentifierTypeSyntax,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        let clause = identifier.genericArgumentClause
        let named = self.named(identifier.name)
        let name = named.name
        // The schema's own name names the schema at the schema's scope, which the expansion checks, and
        // a nested scope could hide it with a member of that name.
        if named.isSchemaName, clause == nil {
            return Reference(
                ResolvedType(key: key(of: Self.schema), reading: .visible),
                scope: Self.schema,
                form: .concrete
            )
            .confirmed(scope == Self.schema)
        }
        let arguments = readArguments(clause, scope, bindings)
        // No visible declaration has the name, so it resolves outside the schema, where another
        // declaration may take a standard-library name.
        if clause == nil, named.mayBeStandard, let standard = ResolvedType.standard(name) {
            return Reference(standard, form: .concrete).confirmed(false)
        }
        if named.mayBeStandard, Self.standardNames.contains(name) {
            return Reference(
                ResolvedType(
                    key: Self.specialized(.standard(name), arguments.keys, clause),
                    reading: .visible,
                    evidence: arguments.evidence,
                    nodes: Self.specializedNodes(clause)
                ),
                form: .unknown
            )
            .confirmed(false)
        }
        // A type declared outside the schema keys as its spelling, which names one type at the schema's
        // scope; a nested scope could hide it with a member the macro cannot see.
        var evidence = arguments.evidence
        evidence.confirmed = evidence.confirmed && scope == Self.schema
        return Reference(
            ResolvedType(
                key: Self.specialized(.outside(named.key), arguments.keys, clause),
                reading: .opaque,
                evidence: evidence,
                nodes: Self.specializedNodes(clause)
            ),
            module: clause == nil ? name : nil,
            form: .unknown
        )
    }

    private func memberReference(_ member: MemberTypeSyntax, _ scope: Int, _ bindings: Bindings) -> Step {
        self.member(member, of: reference(member.baseType, scope, bindings), scope, bindings)
    }

    /// Reads the member `member` spells of the type `base` reads as.
    private func member(_ member: MemberTypeSyntax, of base: Reference, _ scope: Int, _ bindings: Bindings) -> Step {
        let clause = member.genericArgumentClause
        let named = self.named(member.name)
        let name = named.name
        if let selector = member.moduleSelector {
            let arguments = readArguments(clause, scope, bindings)
            var evidence = arguments.evidence
            evidence.add(base.resolved)
            return .done(
                .opaque(
                    Self.specialized(
                        .selectedMember(base.resolved.key, self.named(selector.moduleName).key, named.key),
                        arguments.keys,
                        clause
                    ),
                    evidence,
                    nodes: Self.specializedNodes(clause)
                )
            )
        }
        if let index = base.scope, let number = named.number, scopes[index].members[number] != nil {
            return read(number, in: index, clause: clause, scope, bindings, confirmed: base.resolved.isConfirmed)
        }
        let arguments = readArguments(clause, scope, bindings)
        var evidence = arguments.evidence
        evidence.add(base.resolved)
        // A free `Swift.Never` reads as the standard library's, which only the expansion can confirm.
        if base.module == "Swift" {
            if clause == nil, named.mayBeStandard, let standard = ResolvedType.standard(name) {
                return .done(Reference(standard, form: .concrete).confirmed(false))
            }
            // The key names the standard library's type, not the base, so it counts the arguments alone.
            var standard = ResolvedType(
                key: Self.specialized(.standard(name), arguments.keys, clause),
                reading: .visible,
                evidence: evidence
            )
            standard.size = ResolvedType.counted(arguments.evidence.size + Self.specializedNodes(clause))
            return .done(Reference(standard, form: .unknown).confirmed(false))
        }
        // A member of a type the macro does not read, such as `[Int].Element`, may name any type.
        return .done(
            .opaque(
                Self.specialized(.member(base.resolved.key, named.key), arguments.keys, clause),
                evidence,
                nodes: Self.specializedNodes(clause)
            )
        )
    }

    /// Reads what scope `index` declares under `name`, as a use in `scope` with `clause` names it.
    ///
    /// `confirmed` says whether the lookup that found it is confirmed, which the reading keeps and a
    /// cycle through it needs.
    private func read(
        _ name: Int,
        in index: Int,
        clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings,
        confirmed: Bool
    ) -> Step {
        let id = AliasID(scope: index, name: name)
        switch aliasKind(id) {
        case nil: return .done(readType(name, in: index, clause: clause, scope, bindings).confirmed(confirmed))
        case .nongeneric? where clause == nil: return .done(readNongeneric(id, link: confirmed).confirmed(confirmed))
        default: return readGeneric(id, clause: clause, scope, bindings, confirmed: confirmed)
        }
    }

    private enum AliasKind {
        case nongeneric
        case generic
    }

    /// Whether `id` names an alias, and of which kind, or a type.
    private func aliasKind(_ id: AliasID) -> AliasKind? {
        guard case .alias(let alias)? = scopes[id.scope].members[id.name] else { return nil }
        return alias.parameters.isEmpty ? .nongeneric : .generic
    }

    /// Reads a type a scope declares.
    private func readType(
        _ name: Int,
        in index: Int,
        clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings
    ) -> Reference {
        guard case .type(let members, let isProtocol)? = scopes[index].members[name] else { return cache.unresolved() }
        let arguments = readArguments(clause, scope, bindings)
        return Reference(
            ResolvedType(
                key: Self.specialized(.declared(scopes[index].path + [keyNames[name]]), arguments.keys, clause),
                reading: .visible,
                evidence: arguments.evidence,
                nodes: Self.specializedNodes(clause)
            ),
            scope: clause == nil ? members : nil,
            // A protocol with arguments is a constrained existential, which the macro leaves to the compiler.
            form: isProtocol ? (clause == nil ? .bare : .unknown) : .concrete
        )
    }

    /// What a use of a generic alias reads as before its spelling is read: its memoized or opaque
    /// reading, or the expansion to read and the arguments in place of its parameters.
    private enum GenericUse {
        case read(Reference)
        /// The expansion, and the arguments in place of the parameters.
        case expand(ReadingCache.ExpansionKey, [Int: Int])
    }

    /// Reads a use of a generic alias with its arguments in place of its parameters, when each is a
    /// type, by leaving its spelling for the caller to read in place.
    private func readGeneric(
        _ id: AliasID,
        clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings,
        confirmed: Bool
    ) -> Step {
        switch genericUse(id, clause: clause, scope, bindings) {
        case .read(let reference): return .done(reference.confirmed(confirmed))
        case .expand(let expansion, let substituted):
            // Each argument is read where the use spells it once the spelling reaches its parameter, in
            // place when the spelling is the parameter itself, and an unused one stays unread.
            if let cycle = cycle(id, link: confirmed) {
                return .done(cache.keep(cycle, for: expansion).confirmed(confirmed))
            }
            return .expand(
                Tail(expansion: expansion, confirmed: confirmed, visit: ReadingCache.Visit(id: id, link: confirmed)),
                target: target(of: id),
                scope: id.scope,
                bindings: cache.environment(substituted)
            )
        }
    }

    private func genericUse(
        _ id: AliasID,
        clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings
    ) -> GenericUse {
        guard case .alias(let alias)? = scopes[id.scope].members[id.name] else { return .read(cache.unresolved()) }
        guard let arguments = lazyArguments(clause, scope, bindings) else { return .read(cache.unresolved()) }
        var substituted: [Int: Int] = [:]
        // The compiler rejects arguments to a nongeneric alias, and the wrong number of them.
        if alias.substitutes, !alias.parameters.isEmpty, arguments.count == alias.parameters.count {
            for (parameter, argument) in zip(alias.parameters, arguments) {
                guard case .type(let thunk) = argument else { break }
                substituted[parameter] = substituted[parameter] ?? thunk
            }
        }
        guard !alias.parameters.isEmpty, substituted.count == alias.distinctParameters else {
            let forced = readArguments(clause, scope, bindings)
            return .read(.opaque(.generic(identity(of: id), forced.keys), forced.evidence, nodes: 2))
        }
        let expansion = ReadingCache.ExpansionKey(alias: id, arguments: arguments)
        if let done = cache.expansions[expansion] { return .read(done) }
        guard cache.canRead else { return .read(cache.unresolved()) }
        return .expand(expansion, substituted)
    }

    /// The arguments of a use of a generic alias, each read only once it is used: a parameter of the
    /// alias being read passes on the argument it stands for, and another type is read in `scope`.
    ///
    /// Each argument is charged a step, so a use of an alias with many parameters spends the budget in
    /// proportion to them however often it is expanded; `nil` when the budget runs out first.
    private func lazyArguments(
        _ clause: GenericArgumentClauseSyntax?,
        _ scope: Int,
        _ bindings: Bindings
    ) -> [Argument]? {
        guard let clause else { return [] }
        var arguments: [Argument] = []
        arguments.reserveCapacity(clause.arguments.count)
        for element in clause.arguments {
            cache.step()
            guard cache.canRead else { return nil }
            switch element.argument {
            case .type(let type):
                if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil,
                    identifier.moduleSelector == nil, case .identifier = identifier.name.tokenKind,
                    let name = number(of: identifier.name), let bound = bindings[name]
                {
                    arguments.append(.type(bound))
                } else {
                    arguments.append(.type(cache.thunk(type, scope: scope, bindings: bindings)))
                }
            case .expr(let expression):
                arguments.append(.value(cache.spelling(of: Syntax(expression)).number))
            }
        }
        return arguments
    }

    /// Reads a deferred argument once, where its use spelled it, as a type standing in for a parameter.
    private func force(_ index: Int) -> Reference {
        if let value = cache.thunks[index].value { return value }
        let saved = cache.enter(index)
        let value = reference(cache.thunks[index].type, cache.thunks[index].scope, cache.thunks[index].bindings)
        return cache.leave(index, restoring: saved, with: value)
    }

    /// Reads a nongeneric alias once, keeping what it names.
    ///
    /// While a chain of such aliases is being read, one not read yet is left for later and the alias
    /// that names it is read again once it is, so no reading follows a chain in turn.
    private func readNongeneric(_ id: AliasID, link: Bool) -> Reference {
        if let done = cache.done[id] { return done }
        if cache.deferring {
            // An alias that names a type by a path of names alone reads the same wherever it is reached,
            // so it is read in place, and a reading that reaches it, as the base of a member above all,
            // need not wait for it.
            if let read = readPath(id) { return read }
            let path = cache.chainPathIsConfirmed
            cache.unread[id] = (cache.unread[id] ?? false) || (link && path)
            return .opaque(identity(of: id))
        }
        guard cache.canRead else { return cache.unresolved() }
        readChain(from: id)
        return cache.done[id] ?? cache.unresolved()
    }

    /// What a name in a path names: a reading, or a nongeneric alias and whether the lookup that reached
    /// it is confirmed.
    private enum PathStep {
        case reading(Reference)
        case alias(AliasID, confirmed: Bool)
    }

    /// Reads nongeneric alias `id` in place when its spelling, and the spelling of each nongeneric alias
    /// it names in turn, is a path of names alone, as `Namespace`, `Self`, `Flow.Namespace`, or another
    /// such alias, keeping each alias's reading as reading it on its own would keep it; `nil` for any
    /// other spelling, a path through an alias being read or through itself, or a budget run out.
    ///
    /// Such a reading reads no generic alias and no argument, so it changes nothing a later reading
    /// undoes, and its aliases' readings depend on no alias being read. It follows a chain of aliases in
    /// one loop, charging each name and each scope it looks through, and an alias whose path fails is
    /// remembered, so no path is followed to its failure twice.
    private func readPath(_ id: AliasID) -> Reference? {
        var visited: Set<AliasID> = []
        let read = followPath(from: .alias(id, confirmed: true), &visited)
        if read == nil { cache.pathless.formUnion(visited) }
        return read.map { cache.done[id] ?? $0 }
    }

    /// Follows a path from `first`, keeping the reading of each alias it passes, and returns what
    /// `first` reads as.
    private func followPath(from first: PathStep, _ visited: inout Set<AliasID>) -> Reference? {
        var links: [(id: AliasID, confirmed: Bool)] = []
        var step: PathStep? = first
        var reading: Reference
        while true {
            switch step {
            case nil: return nil
            case .reading(let found)?: reading = found
            case .alias(let id, let confirmed)?:
                if let done = cache.done[id] {
                    reading = done.confirmed(confirmed)
                    break
                }
                guard !cache.pathless.contains(id), visited.insert(id).inserted, !cache.isVisiting(id),
                    aliasKind(id) == .nongeneric
                else { return nil }
                links.append((id, confirmed))
                step = pathStep(target(of: id), id.scope, &visited)
                continue
            }
            break
        }
        // Each alias reads as what its spelling names, and the alias before it as that through its lookup.
        while let link = links.popLast() {
            reading = cache.keep(reading, for: link.id, identity: identity(of: link.id)).confirmed(link.confirmed)
        }
        return reading
    }

    /// What `type`, read in `scope`, names when it is a path of names, or `nil`.
    private func pathStep(_ type: TypeSyntax, _ scope: Int, _ visited: inout Set<AliasID>) -> PathStep? {
        cache.step()
        guard cache.canRead else { return nil }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            // A name without arguments reads no argument, so it reads here as it does anywhere: `Self`, a
            // module selector's type, a name some scope declares, or a name none does.
            guard identifier.genericArgumentClause == nil else { return nil }
            guard identifier.moduleSelector == nil, case .identifier = identifier.name.tokenKind else {
                return .reading(keywordOrSelectedReference(identifier, scope, .none))
            }
            if let name = number(of: identifier.name) {
                switch lookup(name, from: scope) {
                case .found(let index): return member(name, in: index, confirmed: index == scope)
                case .cut: return nil
                case .absent: break
                }
            }
            return .reading(unfoundReference(identifier, scope, .none))
        }
        let parenthesized = type.as(TupleTypeSyntax.self).flatMap(Self.parenthesized)
        let member = type.as(MemberTypeSyntax.self).flatMap { $0.genericArgumentClause == nil ? $0 : nil }
        guard parenthesized != nil || member != nil else { return nil }
        // A base or a parenthesized path is followed to its end, nesting once for each.
        guard cache.depth < Self.depthBudget, cache.depth < Self.stackCheckDepth || Self.hasStackRoom() else {
            return nil
        }
        cache.depth += 1
        defer { cache.depth -= 1 }
        // Parentheses around a single unlabeled type keep what it names, its members, and its metatype, but
        // no module, as the chain reads them, so `(Namespace)` is the path `Namespace`.
        if let parenthesized {
            guard var inner = pathStep(parenthesized, scope, &visited).flatMap({ followPath(from: $0, &visited) })
            else {
                return nil
            }
            inner.module = nil
            return .reading(inner)
        }
        guard let member else { return nil }
        guard let base = pathStep(member.baseType, scope, &visited).flatMap({ followPath(from: $0, &visited) }) else {
            return nil
        }
        if member.moduleSelector == nil, let index = base.scope, let name = number(of: member.name),
            scopes[index].members[name] != nil
        {
            return self.member(name, in: index, confirmed: base.resolved.isConfirmed)
        }
        // A member the macro does not read reads without arguments as it does anywhere.
        guard case .done(let reading) = self.member(member, of: base, scope, .none) else { return nil }
        return .reading(reading)
    }

    /// What scope `index` declares under `name` as a step of a path: a type's reading, a nongeneric alias,
    /// or `nil` for a generic alias, which a path does not read.
    private func member(_ name: Int, in index: Int, confirmed: Bool) -> PathStep? {
        let id = AliasID(scope: index, name: name)
        switch aliasKind(id) {
        case nil: return .reading(readType(name, in: index, clause: nil, index, .none).confirmed(confirmed))
        case .nongeneric?: return .alias(id, confirmed: confirmed)
        case .generic?: return nil
        }
    }

    /// Reads `seed` and every nongeneric alias it waits on, each once, without nesting their readings.
    ///
    /// An alias that waits is read again only once every alias it waits on is read, so a reading waits
    /// at most once for each set of aliases it reaches, whatever order they are read in.
    private func readChain(from seed: AliasID) {
        cache.beginChain()
        defer { cache.endChain() }
        var pending = [seed]
        var enqueued: Set<AliasID> = [seed]
        // The aliases enqueued and not read yet, kept as each is enqueued and read rather than found again.
        var open: Set<AliasID> = [seed]
        var waiting: [AliasID: [AliasID: Bool]] = [:]
        // How many aliases each waiting alias still waits on, and which wait on each alias, by the number of
        // the wait that registered them, so a registration an earlier wait left behind counts for nothing.
        var outstanding: [AliasID: (wait: Int, count: Int)] = [:]
        var dependents: [AliasID: [(id: AliasID, wait: Int)]] = [:]
        var waits = 0
        func finish(_ id: AliasID) {
            open.remove(id)
            waiting[id] = nil
            for dependent in dependents.removeValue(forKey: id) ?? [] {
                guard let left = outstanding[dependent.id], left.wait == dependent.wait else { continue }
                if left.count > 1 {
                    outstanding[dependent.id] = (left.wait, left.count - 1)
                } else {
                    outstanding[dependent.id] = nil
                    pending.append(dependent.id)
                }
            }
        }
        while true {
            var next = 0
            while next < pending.count {
                let id = pending[next]
                next += 1
                // An alias read in place since it was enqueued is finished as one read here is.
                guard cache.done[id] == nil else {
                    finish(id)
                    continue
                }
                // What the reading shares with later ones is logged, so a reading that waits is undone
                // in time proportional to what it changed.
                let mark = cache.mark()
                cache.unread = [:]
                let read = cache.canRead ? expand(id, bindings: .none, link: true) : cache.unresolved()
                if cache.unread.isEmpty {
                    cache.keep(read, for: id, identity: identity(of: id))
                    cache.keep(since: mark)
                    finish(id)
                } else {
                    cache.rollBack(to: mark)
                    waiting[id] = cache.unread
                    waits += 1
                    outstanding[id] = (waits, cache.unread.count)
                    for unread in cache.unread.keys {
                        dependents[unread, default: []].append((id, waits))
                        if enqueued.insert(unread).inserted {
                            open.insert(unread)
                            pending.append(unread)
                        }
                    }
                }
            }
            // What is left waits on itself through other aliases, or on such an alias.
            let left = open
            guard !left.isEmpty else { return }
            // Telling cycles apart spends steps too, and the budget is checked at each one it charges: a
            // search the budget cuts short decides nothing, so every alias left reads as cut, at once.
            guard let circular = cycles(among: left, through: waiting, confirmedOnly: false) else {
                for id in left { cache.keep(cache.unresolved(), for: id, identity: identity(of: id)) }
                return
            }
            guard !circular.isEmpty else {
                // Nothing left is circular, so every alias left waits on one that is now read; each is read
                // again, and a wait it registered before counts for nothing.
                outstanding = [:]
                pending = Array(left)
                continue
            }
            // A cycle through links the macro confirms is reported; one through a link that a member it
            // cannot see could change is left for the compiler, unconfirmed.
            guard let certain = cycles(among: circular, through: waiting, confirmedOnly: true) else {
                for id in left { cache.keep(cache.unresolved(), for: id, identity: identity(of: id)) }
                return
            }
            pending = []
            for id in circular {
                if certain.contains(id) { cache.circular.insert(id) }
                cache.keep(
                    .opaque(identity(of: id), Evidence(confirmed: certain.contains(id))),
                    for: id,
                    identity: identity(of: id)
                )
                outstanding[id] = nil
            }
            for id in circular { finish(id) }
        }
    }

    /// The aliases among `nodes` that lie on a cycle of what each waits on, through confirmed links
    /// only when `confirmedOnly`: those in a strongly connected component of more than one alias, or
    /// that wait on themselves.
    ///
    /// It runs Tarjan's algorithm with its own stack, once over every alias left, in time linear in
    /// the aliases and their links: each alias it opens and each link it inspects, one it follows or one
    /// it passes over, is charged to the reading's steps and checked against the budgets as it is
    /// charged, so no alias's links are gathered before they are paid for; `nil` when a budget runs out
    /// first.
    private func cycles(
        among nodes: Set<AliasID>,
        through waiting: [AliasID: [AliasID: Bool]],
        confirmedOnly: Bool
    ) -> Set<AliasID>? {
        func follows(_ link: (key: AliasID, value: Bool)) -> Bool {
            nodes.contains(link.key) && (link.value || !confirmedOnly)
        }
        var index: [AliasID: Int] = [:]
        var low: [AliasID: Int] = [:]
        var onStack: Set<AliasID> = []
        var stack: [AliasID] = []
        var found: Set<AliasID> = []
        // Each alias being searched, its links, and the position of the next link to inspect.
        var work: [(id: AliasID, links: [AliasID: Bool], next: [AliasID: Bool].Index)] = []
        func open(_ id: AliasID) -> Bool {
            cache.step()
            guard cache.canRead else { return false }
            index[id] = index.count
            low[id] = index[id]
            stack.append(id)
            onStack.insert(id)
            let links = waiting[id] ?? [:]
            work.append((id, links, links.startIndex))
            return true
        }
        for root in nodes where index[root] == nil {
            guard open(root) else { return nil }
            while let top = work.last {
                if top.next < top.links.endIndex {
                    let link = top.links[top.next]
                    work[work.count - 1].next = top.links.index(after: top.next)
                    cache.step()
                    guard cache.canRead else { return nil }
                    guard follows(link) else { continue }
                    if index[link.key] == nil {
                        guard open(link.key) else { return nil }
                    } else if onStack.contains(link.key) {
                        low[top.id] = min(low[top.id] ?? 0, index[link.key] ?? 0)
                    }
                    continue
                }
                work.removeLast()
                if let parent = work.last?.id { low[parent] = min(low[parent] ?? 0, low[top.id] ?? 0) }
                guard low[top.id] == index[top.id] else { continue }
                var component: [AliasID] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    component.append(member)
                    if member == top.id { break }
                }
                let waitsOnItself = top.links[top.id].map { follows((top.id, $0)) } ?? false
                if component.count > 1 || waitsOnItself { found.formUnion(component) }
            }
        }
        return found
    }

    /// Reads an alias's spelling in its own scope with `bindings` for its parameters.
    private func expand(_ id: AliasID, bindings: Bindings, link: Bool) -> Reference {
        if let cycle = cycle(id, link: link) { return cycle }
        cache.push(ReadingCache.Visit(id: id, link: link))
        defer { cache.pop() }
        // An alias of a type reference keeps that type's members, as in `Alias.Member`.
        return reference(target(of: id), id.scope, bindings)
    }

    /// The reading of an alias that is being read already, which names itself: an opaque type, and a
    /// cycle the macro reports when every link through it is confirmed.
    private func cycle(_ id: AliasID, link: Bool) -> Reference? {
        guard let after = cache.confirmedSinceVisit(of: id) else { return nil }
        let certain = link && after
        if certain { cache.circular.insert(id) }
        return .opaque(identity(of: id), Evidence(confirmed: certain))
    }

    /// The spelling an alias names.
    private func target(of id: AliasID) -> TypeSyntax {
        guard case .alias(let alias)? = scopes[id.scope].members[id.name] else {
            return TypeSyntax(MissingTypeSyntax())
        }
        return alias.target
    }

    // MARK: Keys

    /// The key of the type a scope belongs to.
    private func key(of scope: Int) -> TypeKey { .declared(scopes[scope].path) }

    /// The key of an alias as the type it names, unexpanded.
    private func identity(of id: AliasID) -> TypeKey { .alias(scopes[id.scope].path, keyNames[id.name]) }
}

extension LexicalScopes.Evidence {
    fileprivate init(confirmed: Bool) {
        self.init()
        self.confirmed = confirmed
    }
}

/// What the readings of one schema share: the aliases read so far, the deferred arguments of generic
/// aliases, and the budget every reading spends.
private final class ReadingCache {
    struct ResultKey: Hashable {
        let spelling: String
        let scope: Int
    }

    struct ExpansionKey: Hashable {
        let alias: LexicalScopes.AliasID
        let arguments: [LexicalScopes.Argument]
    }

    /// A generic argument read only once a spelling uses the parameter it stands for.
    struct Thunk {
        let type: TypeSyntax
        let scope: Int
        let bindings: LexicalScopes.Bindings
        /// The key it is found by, so undoing its creation removes it.
        let key: ThunkKey
        /// The aliases being read where the argument is spelled: a node of the shared visit tree, so a
        /// deferred argument keeps that stack without a copy of its own.
        let position: Int
        /// The chain of nongeneric aliases being read where the argument is spelled, or 0 for none.
        let chain: Int
        var value: LexicalScopes.Reference?
    }

    /// A deferred argument's spelling where it is read: the number of its tokens' spelling, its scope, and
    /// the number of the arguments it is read with, so finding one hashes neither its spelling again nor
    /// every argument.
    struct ThunkKey: Hashable {
        let spelling: Int
        let scope: Int
        let bindings: Int
    }

    /// An alias being read, and whether the lookup that reached it is confirmed.
    struct Visit {
        let id: LexicalScopes.AliasID
        let link: Bool
    }

    /// One alias being read, as a node of the tree that every stack of aliases being read shares: its
    /// parent is the alias being read where it was reached, `-1` for none.
    ///
    /// A stack is the path from a node to the root, so a deferred argument keeps the stack where it was
    /// spelled as one index, and the count of unconfirmed links on the path tells whether every link
    /// after another node is confirmed without walking it.
    struct VisitNode {
        let visit: Visit
        let parent: Int
        let depth: Int
        /// How many visits on the path to the root, this one included, a lookup the macro cannot
        /// confirm reached.
        let unconfirmed: Int
    }

    /// Where a reading stands among the aliases being read, to restore once a deferred argument is read.
    struct Position {
        let node: Int
        let foreign: Bool
    }

    /// One change a reading inside a chain makes to what later readings share, logged so a reading that
    /// waits on an alias not read yet is undone in time proportional to what it changed.
    private enum Change {
        /// An expansion was kept, over the one it replaced, if any.
        case expansion(ExpansionKey, previous: LexicalScopes.Reference?)
        /// A deferred argument was created, last.
        case thunk
        /// A deferred argument was read, over the reading it had, if any.
        case thunkValue(Int, previous: LexicalScopes.Reference?)
    }

    /// Where the log of a reading inside a chain begins.
    struct Mark {
        fileprivate let position: Int
    }

    var results: [ResultKey: ResolvedType] = [:]
    /// What each nongeneric alias names, kept only through ``keep(_:for:identity:)``.
    private(set) var done: [LexicalScopes.AliasID: LexicalScopes.Reference] = [:]
    /// What each generic alias names with the arguments of a use, kept only through ``keep(_:for:)``.
    private(set) var expansions: [ExpansionKey: LexicalScopes.Reference] = [:]
    var thunks: [Thunk] = []
    var thunkIndex: [ThunkKey: Int] = [:]
    /// The changes the reading in progress inside a chain has made, oldest first.
    private var log: [Change] = []
    /// How many changes readings have logged and undone, for the regression tests' work counts.
    private(set) var loggedChanges = 0
    private(set) var undoneChanges = 0
    /// Each set of a generic alias's arguments, by its number, so an equal set has one number.
    private var environments: [[Int: Int]: Int] = [[:]: 0]
    /// How many arguments interning has hashed, for the regression tests' work counts.
    private(set) var hashedArguments = 0
    /// The spelling key of each syntax node a deferred argument or value argument spells, computed once,
    /// with the node, which keeps its tree, and so the identifier, from being reused by another.
    private var spellings: [SyntaxIdentifier: (node: Syntax, spelling: String, number: Int)] = [:]
    /// The number of each distinct spelling, so two nodes spelled alike share one.
    private var spellingNumbers: [String: Int] = [:]
    /// How many characters of spellings have been hashed to number them, for the regression tests' work
    /// counts: each node's once.
    private(set) var numberedCharacters = 0
    /// How many spelling keys have been computed, for the regression tests' work counts.
    private(set) var spelledNodes = 0
    /// How many nodes of the visit tree moves to and from deferred arguments have walked, for the
    /// regression tests' work counts.
    private(set) var walkedNodes = 0
    /// How many members compositions have flattened in, for the regression tests' work counts.
    private(set) var flattenedMembers = 0
    /// The number of the last reading kept, for ``LexicalScopes/Reference/identity``.
    private var identities = 0

    /// The one rule by which a reading is kept for reuse, as an alias's or a generic alias's use's, by
    /// every path that keeps one: in a chain, along a path, at a cycle, or where a budget ran out.
    ///
    /// A reading not cut short whose key outgrows ``LexicalScopes/keyBudget`` keeps its shape with
    /// `identity` as its key, which is equal to no other spelling's, so what a later reading builds on it
    /// stays within the budget whichever path kept it. A kept reading is numbered, so every later use of
    /// it is known to be the same; a reading kept again with its key unchanged, as an alias that names
    /// another alias keeps it, keeps its number, so a composition that names both flattens it once.
    private func admitted(
        _ reading: LexicalScopes.Reference,
        identity: @autoclosure () -> TypeKey
    ) -> LexicalScopes.Reference {
        assert(reading.resolved.countsItsKey, "\(reading.resolved.size) nodes counted for \(reading.resolved.key)")
        var kept = reading
        if !reading.resolved.isCut, reading.resolved.size > LexicalScopes.keyBudget {
            kept.resolved = ResolvedType(
                key: identity(),
                reading: reading.resolved.reading,
                isFunction: reading.resolved.isFunction,
                isConfirmed: reading.resolved.isConfirmed,
                isShapeConfirmed: reading.resolved.isShapeConfirmed
            )
            kept.identity = nil
        }
        if kept.identity == nil {
            identities += 1
            kept.identity = identities
        }
        return kept
    }

    /// Keeps what nongeneric alias `id` names, through ``admitted(_:identity:)``.
    @discardableResult
    func keep(
        _ reading: LexicalScopes.Reference,
        for id: LexicalScopes.AliasID,
        identity: TypeKey
    ) -> LexicalScopes.Reference {
        let kept = admitted(reading, identity: identity)
        done[id] = kept
        return kept
    }
    /// The visit tree, and the node of the alias being read innermost, `-1` for none.
    private(set) var nodes: [VisitNode] = []
    private var head = -1
    /// The highest node a deferred argument, or a reading of one in progress, keeps.
    private var pinned = -1
    /// The nodes of each alias on the current stack, innermost last, so a reading tells whether it names
    /// an alias it is reading, and where, in constant time however long its chain.
    private var onPath: [LexicalScopes.AliasID: [Int]] = [:]

    private func unconfirmed(_ node: Int) -> Int { node < 0 ? 0 : nodes[node].unconfirmed }
    private func depth(of node: Int) -> Int { node < 0 ? 0 : nodes[node].depth }

    func push(_ visit: Visit) {
        nodes.append(
            VisitNode(
                visit: visit,
                parent: head,
                depth: depth(of: head) + 1,
                unconfirmed: unconfirmed(head) + (visit.link ? 0 : 1)
            )
        )
        head = nodes.count - 1
        onPath[visit.id, default: []].append(head)
    }

    /// Ends reading the innermost alias, reclaiming every node above both the current stack and the
    /// nodes a deferred argument or a reading in progress keeps: such a node lies on no stack in use.
    func pop() {
        leavePath(nodes[head])
        head = nodes[head].parent
        let kept = max(pinned, head)
        if nodes.count - 1 > kept { nodes.removeSubrange((kept + 1)...) }
    }

    private func leavePath(_ node: VisitNode) {
        onPath[node.visit.id]?.removeLast()
        if onPath[node.visit.id]?.isEmpty == true { onPath[node.visit.id] = nil }
    }

    func isVisiting(_ id: LexicalScopes.AliasID) -> Bool { onPath[id] != nil }

    /// Whether every visit after the innermost one of `id` on the current stack was reached through a
    /// confirmed lookup, or `nil` when `id` is not being read.
    func confirmedSinceVisit(of id: LexicalScopes.AliasID) -> Bool? {
        guard let position = onPath[id]?.last else { return nil }
        return unconfirmed(head) == unconfirmed(position)
    }

    /// Moves the current stack to the one ending at `target`, through the node both share.
    ///
    /// Each node it leaves or enters is charged a step, so reading an argument spelled deep in a chain
    /// from a shallow one spends the budget for the depth it moves through. The move always finishes,
    /// so the stack stays whole, and the budget is checked by the reading that follows it.
    private func move(to target: Int) {
        var from = head
        var to = target
        var entered: [Int] = []
        while depth(of: from) > depth(of: to) {
            step(walking: 1)
            leavePath(nodes[from])
            from = nodes[from].parent
        }
        while depth(of: to) > depth(of: from) {
            step(walking: 1)
            entered.append(to)
            to = nodes[to].parent
        }
        while from != to {
            step(walking: 2)
            leavePath(nodes[from])
            from = nodes[from].parent
            entered.append(to)
            to = nodes[to].parent
        }
        for node in entered.reversed() { onPath[nodes[node].visit.id, default: []].append(node) }
        head = target
    }

    /// Charges `count` steps for nodes of the stack that a move walks through.
    private func step(walking count: Int) {
        walkedNodes += count
        readingSteps += count
        totalSteps += count
    }
    /// Whether a nongeneric alias not read yet is left unread while a chain is read.
    private(set) var deferring = false
    /// The chain of nongeneric aliases being read, numbered from 1, with the node where it began.
    private var chain = 0
    private var chains = 0
    private var chainBase = -1
    /// How many deferred arguments spelled outside the chain are being read.
    private var foreign = 0

    func beginChain() {
        deferring = true
        chains += 1
        chain = chains
        chainBase = head
    }

    func endChain() {
        deferring = false
        chain = 0
    }

    /// Whether every alias read since the chain began was reached through a confirmed lookup; a
    /// deferred argument spelled outside the chain is read where it was spelled, so none is.
    var chainPathIsConfirmed: Bool { foreign == 0 && unconfirmed(head) == unconfirmed(chainBase) }
    /// The nongeneric aliases left unread, with whether a confirmed lookup reached each.
    var unread: [LexicalScopes.AliasID: Bool] = [:]
    /// The aliases found to name themselves through confirmed links.
    var circular: Set<LexicalScopes.AliasID> = []
    /// The nongeneric aliases whose spelling, or a spelling they lead to, is no path the macro reads in
    /// place, so each is read in its chain.
    var pathless: Set<LexicalScopes.AliasID> = []
    var readingSteps = 0
    var totalSteps = 0
    /// How deeply the current reading nests.
    var depth = 0
    var exhausted = false
    private var unresolvedCount = 0

    func step() {
        readingSteps += 1
        totalSteps += 1
    }

    /// Charges `count` steps for members a composition flattens in.
    func step(flattening count: Int) {
        flattenedMembers += count
        readingSteps += count
        totalSteps += count
    }

    /// Whether the current reading may read another alias.
    var canRead: Bool {
        guard readingSteps < LexicalScopes.stepBudget, totalSteps < LexicalScopes.totalStepBudget else {
            exhausted = true
            return false
        }
        return true
    }

    private func nextNumber() -> Int {
        unresolvedCount += 1
        return unresolvedCount
    }

    /// What a reading a budget cut short reads as: an unconfirmed opaque type, marked cut.
    func unresolved() -> LexicalScopes.Reference {
        var reference = LexicalScopes.Reference.opaque(.unresolved(nextNumber())).confirmed(false)
        reference.resolved.isCut = true
        return reference
    }

    /// The number of a set of a generic alias's arguments, interned once per expansion that spells it.
    func environment(_ arguments: [Int: Int]) -> LexicalScopes.Bindings {
        hashedArguments += arguments.count
        if let id = environments[arguments] { return LexicalScopes.Bindings(id: id, arguments: arguments) }
        let id = environments.count
        environments[arguments] = id
        return LexicalScopes.Bindings(id: id, arguments: arguments)
    }

    /// The spelling key of a syntax node and its number, computed once however many expansions spell it:
    /// the spelling is hashed once, when it is numbered, and every table keyed by it hashes the number.
    func spelling(of node: Syntax) -> (text: String, number: Int) {
        if let spelled = spellings[node.id] { return (spelled.spelling, spelled.number) }
        spelledNodes += 1
        let spelled = Schema.spellingKey(node)
        let number: Int
        numberedCharacters += spelled.utf8.count
        if let known = spellingNumbers[spelled] {
            number = known
        } else {
            number = spellingNumbers.count
            spellingNumbers[spelled] = number
        }
        spellings[node.id] = (node, spelled, number)
        return (spelled, number)
    }

    /// What a reading needs of the name an identifier token spells, found once for the token however many
    /// readings reach it, so a long name is copied and hashed once rather than at every use of the alias
    /// that spells it.
    struct Named {
        /// The token, which keeps its tree, and so the identifier, from being reused by another.
        let token: TokenSyntax
        /// The name the token looks up, without backticks.
        let name: String
        /// The name as keys hold it.
        let key: KeyName
        /// The number of the name, or `nil` when no scope declares it and no generic alias takes it.
        let number: Int?
        /// Whether it is the schema's own name.
        let isSchemaName: Bool
        /// Whether it is short enough to be a standard-library name the macro knows, which are all under
        /// 32 bytes, so a longer name is told apart from them without hashing it.
        let mayBeStandard: Bool
    }

    private var tokenNames: [SyntaxIdentifier: Named] = [:]
    /// The number of every name a key holds, given when the name is first seen.
    private var keyNumbers: [String: Int] = [:]
    /// How many names keys hold, for the regression tests' work counts.
    var keyNameCount: Int { keyNumbers.count }

    /// `text` as keys hold it, numbered when first seen.
    func keyName(_ text: String) -> KeyName {
        if let number = keyNumbers[text] { return KeyName(number: number, text: text) }
        keyNumbers[text] = keyNumbers.count
        return KeyName(number: keyNumbers.count - 1, text: text)
    }
    /// How many tokens have had their names looked up, for the regression tests' work counts: each once.
    private(set) var namedTokens = 0

    /// What the name a token spells is, as `find` tells the first time it is asked for.
    func named(_ token: TokenSyntax, _ find: (TokenSyntax) -> Named) -> Named {
        if let known = tokenNames[token.id] { return known }
        namedTokens += 1
        let named = find(token)
        tokenNames[token.id] = named
        return named
    }

    func thunk(_ type: TypeSyntax, scope: Int, bindings: LexicalScopes.Bindings) -> Int {
        let key = ThunkKey(spelling: spelling(of: Syntax(type)).number, scope: scope, bindings: bindings.id)
        if let index = thunkIndex[key] { return index }
        pinned = max(pinned, head)
        thunks.append(
            Thunk(type: type, scope: scope, bindings: bindings, key: key, position: head, chain: chain, value: nil)
        )
        thunkIndex[key] = thunks.count - 1
        record(.thunk)
        return thunks.count - 1
    }

    /// Begins reading deferred argument `index` where its use spelled it, returning what to restore.
    func enter(_ index: Int) -> Position {
        let isForeign = deferring && thunks[index].chain != chain
        let saved = Position(node: head, foreign: isForeign)
        pinned = max(pinned, head)
        if isForeign { foreign += 1 }
        move(to: thunks[index].position)
        return saved
    }

    /// Ends reading deferred argument `index`, keeping its reading as a type standing in for a parameter.
    func leave(_ index: Int, restoring saved: Position, with value: LexicalScopes.Reference) -> LexicalScopes.Reference
    {
        move(to: saved.node)
        if saved.foreign { foreign -= 1 }
        var value = value
        value.form = value.form.substituted
        value.module = nil
        record(.thunkValue(index, previous: thunks[index].value))
        thunks[index].value = value
        return value
    }

    /// Keeps a generic alias's reading with the arguments of a use, through ``admitted(_:identity:)``;
    /// a reading too large to keep has a key equal to no other.
    func keep(_ reading: LexicalScopes.Reference, for expansion: ExpansionKey) -> LexicalScopes.Reference {
        let kept = admitted(reading, identity: .distinct(nextNumber()))
        record(.expansion(expansion, previous: expansions[expansion]))
        expansions[expansion] = kept
        return kept
    }

    /// Logs a change while a chain is read, the only time a reading is undone.
    private func record(_ change: Change) {
        guard deferring else { return }
        log.append(change)
        loggedChanges += 1
    }

    /// Begins logging the changes of one reading inside a chain.
    func mark() -> Mark { Mark(position: log.count) }

    /// Keeps every change since `mark`, which no later reading undoes.
    func keep(since mark: Mark) { log.removeSubrange(mark.position...) }

    /// Undoes every change since `mark`, newest first.
    func rollBack(to mark: Mark) {
        while log.count > mark.position {
            undoneChanges += 1
            switch log.removeLast() {
            case .expansion(let key, let previous): expansions[key] = previous
            case .thunk:
                let removed = thunks.removeLast()
                thunkIndex[removed.key] = nil
            case .thunkValue(let index, let previous): thunks[index].value = previous
            }
        }
    }
}

/// An authored type spelling read through the declarations the macro can see.
struct ResolvedType: Equatable {
    /// What a spelling names, as far as the macro can tell.
    enum Reading: Equatable {
        /// The standard library's `Void`.
        case void
        /// The standard library's `Never`.
        case never
        /// A type the schema declares, a standard-library type other than `Void` and `Never`, or a
        /// structural type such as an optional, a collection, a function, or a tuple of several elements.
        case visible
        /// A type the macro cannot see into: one declared outside the schema, a member of a type whose
        /// members it does not read, or a generic alias it cannot expand. Any of them may name `Void` or
        /// `Never`.
        case opaque
    }

    /// The identity of the type, with every visible alias replaced by what it names, every type the
    /// schema declares named by its path, and the standard library's `Void`, `Never`, and sugared types
    /// named through its module, so spellings of one type share one key.
    let key: TypeKey
    let reading: Reading
    /// Whether the spelling visibly names a function type, which a parameter must mark `@escaping` to
    /// store or pass to a generic parameter.
    var isFunction = false
    /// Whether nothing the macro cannot see could change the reading or the key.
    var isConfirmed = true
    /// Whether nothing the macro cannot see could change what kind of type it is.
    ///
    /// The kind, `Void`, `Never`, a function type, or another type with values, is what the generated
    /// shape rests on. A type spelled by its structure, such as `(A, B)` or `() -> A`, confirms its kind
    /// whatever the types inside it name; a name confirms it only through lookups the macro confirms.
    var isShapeConfirmed = true
    /// Whether a budget cut the reading short, so nothing may be concluded from it: the declaration
    /// that spells it is diagnosed instead.
    var isCut = false
    /// The nodes of the key, counted as the key is built from the readings inside it and no further than
    /// one past ``LexicalScopes/keyBudget``, so telling whether a key outgrows the budget takes no walk.
    var size = 1

    /// Two readings are equal when everything but their node count, which their keys decide, is.
    static func == (lhs: ResolvedType, rhs: ResolvedType) -> Bool {
        lhs.key == rhs.key && lhs.reading == rhs.reading && lhs.isFunction == rhs.isFunction
            && lhs.isConfirmed == rhs.isConfirmed && lhs.isShapeConfirmed == rhs.isShapeConfirmed
            && lhs.isCut == rhs.isCut
    }

    /// Whether the spelling names the standard library's `Void`.
    var isVoid: Bool { reading == .void }
    /// Whether the spelling names the standard library's `Never`.
    var isNever: Bool { reading == .never }
    /// Whether the spelling names a type the macro cannot see into.
    var isOpaque: Bool { reading == .opaque }
    /// Whether the macro confirms what kind of type this is; a type it cannot see into has no known kind.
    var confirmsShape: Bool { isShapeConfirmed && reading != .opaque }
    /// Whether the macro confirms the type is the standard library's `Never`.
    var isConfirmedNever: Bool { confirmsShape && isNever }
    /// Whether the macro confirms the type is other than `Never`, so it has values.
    var confirmsValues: Bool { confirmsShape && !isNever }
    /// Whether the macro confirms the type is a function type.
    var isConfirmedFunction: Bool { confirmsShape && isFunction }

    /// The reading of the standard-library `name` when it is one whose kind the shape rests on: `Void`,
    /// `Never`, or `UnboundedRange`, the alias of `(Swift::UnboundedRange_) -> ()`; or `nil`.
    static func standard(_ name: String) -> ResolvedType? {
        switch name {
        case "Void": ResolvedType(key: .tuple([]), reading: .void)
        case "Never": ResolvedType(key: .standard("Never"), reading: .never)
        case "UnboundedRange":
            ResolvedType(
                key: .function(
                    TypeKey.FunctionKey(
                        parameters: [
                            TypeKey.FunctionKey.Parameter(
                                conventions: [],
                                type: .standard("UnboundedRange_"),
                                isVariadic: false
                            )
                        ],
                        isAsync: false,
                        thrown: .none,
                        result: .tuple([])
                    )
                ),
                reading: .visible,
                isFunction: true,
                size: 3
            )
        default: nil
        }
    }

    /// The standard library's types, protocols, and aliases that the macro knows name a type with values
    /// other than a function type, so naming one through `Swift::` confirms that kind.
    ///
    /// Every other standard name, such as a caseless namespace like `Unicode`, reads with its kind
    /// unconfirmed, which the expansion checks wherever the shape rests on it.
    static let standardValueTypes: Set<String> = [
        // Numbers, text, and other values.
        "Bool", "Character", "Double", "Duration", "Float", "Float16", "Float32", "Float64", "Float80", "Int",
        "Int8", "Int16", "Int32", "Int64", "Int128", "ObjectIdentifier", "StaticString", "String", "Substring",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "AnyHashable", "Hasher", "Mirror",
        "CBool", "CChar", "CChar8", "CChar16", "CChar32", "CDouble", "CFloat", "CFloat16", "CInt", "CLong",
        "CLongDouble", "CLongLong", "CShort", "CSignedChar", "CUnsignedChar", "CUnsignedInt", "CUnsignedLong",
        "CUnsignedLongLong", "CUnsignedShort", "CWideChar", "BooleanLiteralType", "ExtendedGraphemeClusterType",
        "FloatLiteralType", "IntegerLiteralType", "StringLiteralType", "UnicodeScalarType",
        // Generic values and collections.
        "Array", "ArraySlice", "ClosedRange", "CollectionOfOne", "ContiguousArray", "Dictionary",
        "EmptyCollection", "InlineArray", "KeyValuePairs", "Optional", "PartialRangeFrom", "PartialRangeThrough",
        "PartialRangeUpTo", "Range", "RangeSet", "Result", "Set", "Slice", "Span", "MutableSpan", "RawSpan",
        "MutableRawSpan", "Unmanaged", "OpaquePointer", "UnsafePointer", "UnsafeMutablePointer",
        "UnsafeRawPointer", "UnsafeMutableRawPointer", "UnsafeBufferPointer", "UnsafeMutableBufferPointer",
        "UnsafeRawBufferPointer", "UnsafeMutableRawBufferPointer", "AnyKeyPath", "PartialKeyPath", "KeyPath",
        "WritableKeyPath", "ReferenceWritableKeyPath", "DecodingError", "EncodingError", "CodingUserInfoKey",
        // Protocols, whose existentials have values, and the aliases of compositions and metatypes.
        "AdditiveArithmetic", "AnyObject", "AnyClass", "BidirectionalCollection", "BinaryFloatingPoint",
        "BinaryInteger", "BitwiseCopyable", "CaseIterable", "Codable", "CodingKey", "Collection", "Comparable",
        "Copyable", "CustomDebugStringConvertible", "CustomStringConvertible", "Decodable", "Decoder", "Encodable",
        "Encoder", "Equatable", "Error", "Escapable", "FixedWidthInteger", "FloatingPoint", "Hashable",
        "Identifiable", "IteratorProtocol", "LosslessStringConvertible", "MutableCollection", "Numeric",
        "OptionSet", "RandomAccessCollection", "RandomNumberGenerator", "RangeExpression",
        "RangeReplaceableCollection", "RawRepresentable", "Sendable", "SendableMetatype", "Sequence", "SetAlgebra",
        "SignedInteger", "SignedNumeric", "Strideable", "StringProtocol", "TextOutputStream", "UnsignedInteger",
    ]
}

extension ResolvedType {
    /// A reading of `key` that folds in the readings of `evidence`, whose keys are inside it, and whose
    /// key has `nodes` nodes of its own besides theirs.
    fileprivate init(
        key: TypeKey,
        reading: Reading,
        isFunction: Bool = false,
        evidence: LexicalScopes.Evidence,
        nodes: Int = 1
    ) {
        self.init(
            key: key,
            reading: reading,
            isFunction: isFunction,
            isConfirmed: evidence.confirmed,
            isShapeConfirmed: true,
            isCut: evidence.cut,
            size: Self.counted(evidence.size + nodes)
        )
    }

    /// `count` nodes, or one past ``LexicalScopes/keyBudget`` when there are more, which is all a reading
    /// needs to know of a key that large.
    static func counted(_ count: Int) -> Int { min(count, LexicalScopes.keyBudget + 1) }

    /// Whether the count of a reading not cut short is its key's, which the debug build checks wherever a
    /// reading is kept; a cut reading's key is left unfinished, so it is never kept or concluded from.
    var countsItsKey: Bool { isCut || size == key.nodes(upTo: LexicalScopes.keyBudget + 1) }
}

extension TypeSyntax {
    /// The type inside any parentheses that enclose this one, which Swift reads as that type: `T` for
    /// `(T)`, `((T))`, or `(_: T)`.
    ///
    /// The schema parser takes every type it reads from the declaration through this, so no test of a
    /// type's shape sees the parentheses.
    var unparenthesized: TypeSyntax {
        var type = self
        while let tuple = type.as(TupleTypeSyntax.self), let only = LexicalScopes.parenthesized(tuple) { type = only }
        return type
    }
}

extension GenericArgumentSyntax {
    /// The argument's type without enclosing parentheses, or `nil` for a value argument.
    var type: TypeSyntax? {
        guard case .type(let type) = argument else { return nil }
        return type.unparenthesized
    }
}
