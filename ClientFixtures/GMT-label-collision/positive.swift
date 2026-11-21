import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Printer: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case print }
    @Operation(activeIn: [Idle.self])
    enum OnPrint {}
    @Event enum Printed {}
    @Transition(on: Input.print, starts: [OnPrint.self], emits: [Printed.self])
    fileprivate static func print(_ source: Idle) -> Change<Idle, Effect.Print> {
        Change(source, effects: [.onPrint, .printed])
    }
    @Transition(onSuccess: OnPrint.self)
    fileprivate static func done(_ source: Idle) -> Idle { source }
}

@MainActor func makePrinter() -> Printer.MainActorHost {
    Printer.MainActorHost(Printer.Idle(), onPrintDriver: {}, onPrinted: {})
}
