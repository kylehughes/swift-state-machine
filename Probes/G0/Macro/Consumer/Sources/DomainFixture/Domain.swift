import DomainMacro

@ProbeDomain
public struct Domain {}

// Describes an edge only; no authority factory accepts this protocol.
public protocol EdgeDescription {
    static var name: String { get }
}
