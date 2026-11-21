/// What one execution of an operation that carries an input was started with, as admission accepted it.
///
/// Every generated schema names this type `<Operation>Request` for an operation without a `Key` whose
/// work carries its `Input`, specialized at the operation's namespace, so each operation's requests
/// are a type of their own. It is plain data: constructing one grants no authority. It stores an
/// input of any type, a closure included, and is `Sendable`, `Equatable`, and `Hashable` when its
/// input is.
nonisolated public struct OperationRequest<Operation, Input> {
    /// The input the work was started with.
    public let input: Input

    /// Creates a request; it is plain data and grants no authority.
    public init(input: Input) { self.input = input }
}

extension OperationRequest: Sendable where Input: Sendable {}
extension OperationRequest: Equatable where Input: Equatable {}
extension OperationRequest: Hashable where Input: Hashable {}

/// What one execution of a keyed operation that carries an input was started with, as admission
/// accepted it.
///
/// Every generated schema names this type `<Operation>Request` for an operation with a `Key` whose
/// work carries its `Input`, specialized at the operation's namespace, so each operation's requests
/// are a type of their own. It is plain data: constructing one grants no authority. It is `Sendable`,
/// `Equatable`, and `Hashable` when its input is.
nonisolated public struct KeyedOperationRequest<Operation, Key: Hashable & Sendable, Input> {
    /// The key the work was started for.
    public let key: Key
    /// The input the work was started with.
    public let input: Input

    /// Creates a request; it is plain data and grants no authority.
    public init(key: Key, input: Input) {
        self.key = key
        self.input = input
    }
}

extension KeyedOperationRequest: Sendable where Input: Sendable {}
extension KeyedOperationRequest: Equatable where Input: Equatable {}
extension KeyedOperationRequest: Hashable where Input: Hashable {}
