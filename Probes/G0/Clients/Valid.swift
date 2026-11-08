import os
import ProbeCore

public func ownedControl() {
    guard let request = Request("request") else { return }
    let original = start(Idle("initial"))
    switch original.begin(request, allowed: false) {
    case .advanced(let next, effects: let effects):
        precondition(effects == [.log("initial"), .fetch("request")])
        let idle = next.cancel()
        precondition(idle.withValue { $0.name } == "request")
    case .rejected(.denied, let recovered):
        precondition(recovered.withValue { $0.name } == "initial")
        switch recovered.begin(request, allowed: true) {
        case .advanced(let next, effects: let effects):
            precondition(effects == [.log("initial"), .fetch("request")])
            precondition(next.withValue { $0.request } == "request")
        case .rejected: preconditionFailure("recovery failed")
        }
    }
}
public func dynamicControl() {
    guard let request = Request("request") else { return }
    let host = Shared(Idle("initial"))
    let other = Shared(Idle("initial"))
    guard case .idle(let idle) = host.snapshot() else { preconditionFailure() }
    precondition(other.commit(idle.begin(request)) == .foreign)
    precondition(host.commit(idle.begin(request)) == .accepted)
    precondition(host.commit(idle.begin(request)) == .conflict)
    guard case .loading(let loading) = host.snapshot() else { preconditionFailure() }
    precondition(loading.value.request == "request")
    precondition(host.commit(loading.cancel()) == .accepted)
    host.close()
    precondition(host.isClosed)
    precondition(host.commit(idle.begin(request)) == .closed)
}
public func sharedTaskControl() async {
    let host = AdmissionHost()
    let work = await host.issueFetch("request")
    let task = sharedWorker(work, host: host)
    await task.value
    let value = await host.read()
    precondition(value == "REQUEST")
}
@MainActor public func isolatedControl() async {
    let host = IsolatedHost()
    let value = IsolatedValue("request")
    host.run(value)
    await host.join()
    precondition(host.read().text == "REQUEST")
}
