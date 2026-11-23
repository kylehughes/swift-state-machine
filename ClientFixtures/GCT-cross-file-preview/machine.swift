import StateMachine

#if canImport(SwiftUI)
import SwiftUI
#endif

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
nonisolated enum LocalPreviewMachine {
    struct Configuring {}
    struct Saved {}

    @Initial
    case configuring(Configuring = Configuring())
    @Terminal
    case saved(Saved)

    enum Input {
        case save
    }

    @Transition(on: Input.save)
    fileprivate static func save(_ source: Configuring) -> Saved {
        Saved()
    }
}

extension LocalPreviewMachine {
    @MainActor
    static func makeMainActorHost() -> MainActorHost {
        MainActorHost()
    }
}

#if canImport(SwiftUI)
@MainActor
struct PreviewContainer<Content> where Content: View {
    let content: (Int) -> Content

    init(content: @escaping (Int) -> Content) {
        self.content = content
    }
}

extension PreviewContainer: View {
    var body: some View {
        content(1)
    }
}
#endif
