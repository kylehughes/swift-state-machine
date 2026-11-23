import CrossFilePreviewLibrary
import StateMachine

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(SwiftUI)
@MainActor
private struct EndView: View {
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

    static func makeDirectControl() -> some View {
        PreviewContainer { _ in
            let flowMachine = LocalPreviewMachine.MainActorHost()
            return NavigationStack {
                EndView(flowMachine: flowMachine)
            }
        }
    }
}

@MainActor
private struct ImportedEndView: View {
    private let flowMachine: ImportedPreviewMachine.MainActorHost

    init(flowMachine: ImportedPreviewMachine.MainActorHost) {
        self.flowMachine = flowMachine
    }

    var body: some View {
        switch flowMachine.currentSnapshot {
        case .configuring:
            Text("Configuring")
        case .saved:
            Text("Saved")
        @unknown default:
            Text("Other")
        }
    }
}

#if canImport(DeveloperToolsSupport)
#Preview("Same-module static factory") {
    PreviewContainer { _ in
        let flowMachine = LocalPreviewMachine.makeMainActorHost()
        return NavigationStack {
            EndView(flowMachine: flowMachine)
        }
    }
}

#Preview("Same-module view helper") {
    EndView.makeDirectControl()
}

#Preview("Separate-module inline host") {
    PreviewContainer { _ in
        let flowMachine = ImportedPreviewMachine.MainActorHost()
        return NavigationStack {
            ImportedEndView(flowMachine: flowMachine)
        }
    }
}
#endif
#endif

@main
@MainActor
struct CrossFilePreviewRunner {
    static func main() throws {
        let direct = LocalPreviewMachine.MainActorHost()
        let factory = LocalPreviewMachine.makeMainActorHost()
        let imported = ImportedPreviewMachine.MainActorHost()

        #if canImport(SwiftUI)
        _ = EndView.makeDirectControl()
        let localContainer = PreviewContainer { _ in
            EndView(flowMachine: factory)
        }
        _ = localContainer.body
        let importedContainer = PreviewContainer { _ in
            ImportedEndView(flowMachine: imported)
        }
        _ = importedContainer.body
        #endif

        let directReceipt = try direct.send(.save)
        let factoryReceipt = try factory.send(.save)
        let importedReceipt = try imported.send(.save)

        guard
            case .saved = directReceipt.snapshot,
            case .saved = factoryReceipt.snapshot,
            case .saved = importedReceipt.snapshot,
            direct.currentSnapshot.revision == 1,
            factory.currentSnapshot.revision == 1,
            imported.currentSnapshot.revision == 1
        else {
            fatalError("Unexpected cross-file preview host state")
        }
        print("CROSS-FILE-PREVIEW-OK")
    }
}
