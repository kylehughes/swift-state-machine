import os
import ProbeCore
func misuse(_ request: Request) -> () -> Void {
    let original = start(Idle("initial"))
    return { _ = original.begin(request, allowed: true) }
}
