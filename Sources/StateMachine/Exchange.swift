/// Replaces the value in `slot` and returns the value it held.
///
/// Code that changes state inside a lock uses it to hand a replaced value, which can hold the last
/// reference to an element, a token, or a closure, out of the lock, so that the value's destructor
/// runs only after unlocking.
nonisolated package func exchange<Value>(_ slot: inout Value, with value: Value) -> Value {
    var replaced = value
    swap(&slot, &replaced)
    return replaced
}
