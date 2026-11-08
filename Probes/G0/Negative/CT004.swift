import os
import ProbeCore
func misuse() {
    let original = start(Idle("initial"))
    _ = original.begin("unvalidated", allowed: true)
}
