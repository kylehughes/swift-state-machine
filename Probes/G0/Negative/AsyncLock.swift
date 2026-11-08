import os
import ProbeCore
func misuse() {
    let lock = OSAllocatedUnfairLock(initialState: 0)
    lock.withLock { value in
        await Task.yield()
        value += 1
    }
}
