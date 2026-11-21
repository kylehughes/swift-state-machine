import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Checkout: Sendable {
    struct Cart: Sendable { var items: [String] = [] }
    struct Paying: Sendable { let items: [String] }
    struct Confirming: Sendable { let items: [String] }
    struct Paid: Sendable { let receipt: String }
    @Initial case cart(Cart = Cart())
    case paying(Paying)
    case confirming(Confirming)
    @Terminal case paid(Paid)
    enum Scope {
        @Active(in: [Paying.self, Confirming.self])
        case payment
        case session
    }
    enum Input: Sendable { case add(String), pay, confirm }
    @Operation(scope: Scope.payment, requires: [Scope.session])
    enum Charge {
        typealias Input = [String]
        typealias Output = String
    }
    @Event
    enum Tracked { typealias Payload = String }
    @Event
    enum Pinged {}
    @Transition(on: Input.add, emits: [Tracked.self])
    fileprivate static func add(_ source: Cart, _ item: String) -> Change<Cart, Effect.Add> {
        Change(Cart(items: source.items + [item]), effects: [.tracked(item)])
    }
    @Transition(on: Input.pay, starts: [Charge.self], emits: [Tracked.self, Pinged.self])
    fileprivate static func pay(_ source: Cart) -> Change<Paying, Effect.Pay> {
        Change(Paying(items: source.items), effects: [.tracked("pay"), .charge(source.items), .pinged])
    }
    @Transition(on: Input.confirm)
    fileprivate static func confirm(_ source: Paying) -> Confirming { Confirming(items: source.items) }
    @Transition(onSuccess: Charge.self)
    fileprivate static func charged(_ source: Paying, _ receipt: Charge.Output) -> Paid { Paid(receipt: receipt) }
    @Transition(onSuccess: Charge.self)
    fileprivate static func charged(_ source: Confirming, _ receipt: Charge.Output) -> Paid { Paid(receipt: receipt) }
}

@StateMachine(mode: .isolated, owners: [.local])
nonisolated enum Tally {
    struct Counting { var count = 0 }
    @Initial case counting(Counting = Counting())
    enum Input { case add }
    @Event
    enum Counted { typealias Payload = Int }
    @Transition(on: Input.add, emits: [Counted.self])
    fileprivate static func add(_ source: Counting) -> Change<Counting, Effect.Add> {
        Change(Counting(count: source.count + 1), effects: [.counted(source.count + 1)])
    }
}

@StateMachine(mode: .ownedOnly)
nonisolated enum Ticket: ~Copyable {
    struct Valid: ~Copyable { let seat: Int }
    struct Used: ~Copyable { let seat: Int }
    @Initial case valid(Valid)
    @Terminal case used(Used)
    @Event
    enum Scanned { typealias Payload = Int }
    @Transition(emits: [Scanned.self])
    fileprivate static func scan(_ source: consuming Valid) -> Change<Used, Effect.Scan> {
        let seat = source.seat
        return Change(Used(seat: seat), effects: [.scanned(seat)])
    }
}
