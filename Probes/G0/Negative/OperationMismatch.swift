import os
import ProbeCore
func misuse(_ host: AdmissionHost) async {
    let work = await host.issueSave()
    await host.admit(work.succeeded("same string shape"))
}
