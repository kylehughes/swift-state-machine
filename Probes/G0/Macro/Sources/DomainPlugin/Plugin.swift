import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct ProbeDomainMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let source = """
struct Members {
public enum OperationA: Sendable {}
public enum OperationB: Sendable {}
public struct Snapshot: Sendable {
    public let value: Int
    fileprivate let revision: Int
    fileprivate init(value: Int, revision: Int) {
        self.value = value
        self.revision = revision
    }
}
public struct Prepared: ~Copyable {
    fileprivate let destination: Int
    fileprivate let revision: Int
    fileprivate init(destination: Int, revision: Int) {
        self.destination = destination
        self.revision = revision
    }
}
public struct Ticket<Operation: Sendable>: Sendable {
    fileprivate let identity: Int
    fileprivate let generation: Int
    fileprivate init(identity: Int, generation: Int) {
        self.identity = identity
        self.generation = generation
    }
}
public struct Completion<Operation: Sendable>: Sendable {
    fileprivate let ticket: Ticket<Operation>
    public let output: Int
    fileprivate init(ticket: Ticket<Operation>, output: Int) {
        self.ticket = ticket
        self.output = output
    }
}
public struct Work: Sendable {
    public let ticket: Ticket<OperationA>
    public let input: Int
    public func complete(output: Int) -> Completion<OperationA> {
        Completion(ticket: ticket, output: output)
    }
    fileprivate init(ticket: Ticket<OperationA>, input: Int) {
        self.ticket = ticket
        self.input = input
    }
}
private var value: Int = 0
private var revision: Int = 0
public init() {}
public var snapshot: Snapshot {
    Snapshot(value: value, revision: revision)
}
public func prepareIncrement(from snapshot: Snapshot) -> Prepared? {
    guard snapshot.revision == revision, snapshot.value == value else { return nil }
    return Prepared(destination: value + 1, revision: revision)
}
public mutating func commit(_ change: consuming Prepared) -> Bool {
    guard change.revision == revision else { return false }
    value = change.destination
    revision += 1
    return true
}
public func start() -> Work {
    Work(ticket: Ticket(identity: value, generation: revision), input: value)
}
public mutating func admit(_ completion: Completion<OperationA>) -> Bool {
    guard completion.ticket.identity == value, completion.ticket.generation == revision else { return false }
    value = completion.output
    revision += 1
    return true
}
}
"""
        guard let container = DeclSyntax(stringLiteral: source).as(StructDeclSyntax.self) else {
            return []
        }
        return container.memberBlock.members.map(\.decl)
    }
}

@main
struct DomainPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ProbeDomainMacro.self]
}
