// A chain of 68 aliases ending in () reads as Void, so the success edge takes no output.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    typealias A0 = A1
    typealias A1 = A2
    typealias A2 = A3
    typealias A3 = A4
    typealias A4 = A5
    typealias A5 = A6
    typealias A6 = A7
    typealias A7 = A8
    typealias A8 = A9
    typealias A9 = A10
    typealias A10 = A11
    typealias A11 = A12
    typealias A12 = A13
    typealias A13 = A14
    typealias A14 = A15
    typealias A15 = A16
    typealias A16 = A17
    typealias A17 = A18
    typealias A18 = A19
    typealias A19 = A20
    typealias A20 = A21
    typealias A21 = A22
    typealias A22 = A23
    typealias A23 = A24
    typealias A24 = A25
    typealias A25 = A26
    typealias A26 = A27
    typealias A27 = A28
    typealias A28 = A29
    typealias A29 = A30
    typealias A30 = A31
    typealias A31 = A32
    typealias A32 = A33
    typealias A33 = A34
    typealias A34 = A35
    typealias A35 = A36
    typealias A36 = A37
    typealias A37 = A38
    typealias A38 = A39
    typealias A39 = A40
    typealias A40 = A41
    typealias A41 = A42
    typealias A42 = A43
    typealias A43 = A44
    typealias A44 = A45
    typealias A45 = A46
    typealias A46 = A47
    typealias A47 = A48
    typealias A48 = A49
    typealias A49 = A50
    typealias A50 = A51
    typealias A51 = A52
    typealias A52 = A53
    typealias A53 = A54
    typealias A54 = A55
    typealias A55 = A56
    typealias A56 = A57
    typealias A57 = A58
    typealias A58 = A59
    typealias A59 = A60
    typealias A60 = A61
    typealias A61 = A62
    typealias A62 = A63
    typealias A63 = A64
    typealias A64 = A65
    typealias A65 = A66
    typealias A66 = A67
    typealias A67 = A68
    typealias A68 = ()
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Output = A0 }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
