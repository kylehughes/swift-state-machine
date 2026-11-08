import os
import ProbeCore
struct Unique: ~Copyable {}
func misuse() {
    let lock = OSAllocatedUnfairLock(initialState: 0)
    let result: Unique = lock.withLock { _ -> Unique in return Unique() }
    _ = consume result
}
