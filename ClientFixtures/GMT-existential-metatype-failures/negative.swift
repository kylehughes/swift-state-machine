// The rejection case of the metatype of an existential does not take the existential metatype's failure.
import StateMachine

public protocol Part {}
public struct Problem<Value>: Swift::Error { public init() {} }

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Picker: Sendable {
    struct Idle: Sendable {}
    struct A: Sendable {}
    struct B: Sendable {}
    @Initial case idle(Idle)
    @Terminal case a(A)
    @Terminal case b(B)
    enum Input: Sendable { case go }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .left }
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<any Part.Type>) -> A { A() }
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<(any Part).Type>) -> B { B() }
}
func check() {
    let rejection = Picker.PreparationRejection.right(Problem<any Part.Type>())
    _ = rejection
}
