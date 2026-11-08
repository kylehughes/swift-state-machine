import os
import ProbeCore
@MainActor func misuse() {
    requireSendable(IsolatedValue("still not Sendable"))
}
