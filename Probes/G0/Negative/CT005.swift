import os
import ProbeCore
func misuse(_ request: Request) {
    let host = Shared(Idle("initial"))
    guard case .idle(let idle) = host.snapshot() else { return }
    let prepared = idle.begin(request)
    _ = host.commit(prepared)
    _ = host.commit(prepared)
}
