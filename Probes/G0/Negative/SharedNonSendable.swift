import os
import ProbeCore
func misuse() {
    _ = OSAllocatedUnfairLock(initialState: IsolatedValue("not shared"))
}
