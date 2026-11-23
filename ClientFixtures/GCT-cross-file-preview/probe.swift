import StateMachine

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(SwiftUI)
@MainActor
private struct ProbeEndView: View {
    private let flowMachine: LocalPreviewMachine.MainActorHost

    init(flowMachine: LocalPreviewMachine.MainActorHost) {
        self.flowMachine = flowMachine
    }

    var body: some View {
        switch flowMachine.currentSnapshot {
        case .configuring:
            Text("Configuring")
        case .saved:
            Text("Saved")
        }
    }
}

#if canImport(DeveloperToolsSupport)
#Preview("Same-module inline host probe") {
    PreviewContainer { _ in
        let flowMachine = LocalPreviewMachine.MainActorHost()
        return NavigationStack {
            ProbeEndView(flowMachine: flowMachine)
        }
    }
}
#endif
#endif
