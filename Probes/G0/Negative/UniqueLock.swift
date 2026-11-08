import os
import ProbeCore
struct Unique: ~Copyable {}
func misuse() { _ = OSAllocatedUnfairLock(initialState: Unique()) }
