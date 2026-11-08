import os
import ProbeCore
nonisolated func misuse(_ host: IsolatedHost) async {
    let result = await host.read()
    print(result.text)
}
