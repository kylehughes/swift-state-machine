import os
import ProbeCore
func misuse(_ request: Request) {
    let original = start(Idle("initial"))
    _ = original.begin(request, allowed: true)
    _ = original.withValue { $0.name }
}
