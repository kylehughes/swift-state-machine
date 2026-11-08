import os
import ProbeCore
func misuse(_ request: Request) {
    let original = start(Idle("initial"))
    let alias = original
    _ = original.begin(request, allowed: true)
    _ = alias.begin(request, allowed: true)
}
