// Separate library-evolution module exercising public schemas with generic <Source> @Transition(from:),
// private/fileprivate protocols and @PhaseSets, combined generic+routed, and .ownedOnly ~Copyable Advance.
// None of the fileprivate protocols, @PhaseSets, or fileprivate routed choice enums may leak into .swiftinterfaces.
import StateMachine

private nonisolated protocol PrivateSelectionCarrying {
    var selectedListID: Int? { get set }
}

private nonisolated protocol PrivateTagged {
    var tag: Int { get }
    var note: String { get set }
}

private nonisolated protocol PrivateUniqueTitled: ~Copyable {
    var title: String { get set }
}

@StateMachine(mode: .shared, owners: [.owned, .local, .shared])
public nonisolated enum NavigationPublicFlow: Sendable {
    public struct Browsing: Sendable, PrivateSelectionCarrying {
        public var selectedListID: Int?
        public init(selectedListID: Int? = nil) { self.selectedListID = selectedListID }
    }
    public struct Confirming: Sendable, PrivateSelectionCarrying {
        public let prompt: String
        public var selectedListID: Int?
        public init(prompt: String, selectedListID: Int?) {
            self.prompt = prompt
            self.selectedListID = selectedListID
        }
    }
    public struct PresentingSheet: Sendable, PrivateSelectionCarrying {
        public let sheet: String
        public var selectedListID: Int?
        public init(sheet: String, selectedListID: Int?) {
            self.sheet = sheet
            self.selectedListID = selectedListID
        }
    }
    public struct PresentingSheetConfirming: Sendable, PrivateSelectionCarrying {
        public let prompt: String
        public let sheet: String
        public var selectedListID: Int?
        public init(prompt: String, sheet: String, selectedListID: Int?) {
            self.prompt = prompt
            self.sheet = sheet
            self.selectedListID = selectedListID
        }
    }
    public struct PendingNavigation: Sendable, PrivateSelectionCarrying {
        public let destination: String
        public var selectedListID: Int?
        public init(destination: String, selectedListID: Int?) {
            self.destination = destination
            self.selectedListID = selectedListID
        }
    }
    public struct Maintenance: Sendable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    @Initial case browsing(Browsing = Browsing())
    case confirming(Confirming)
    case presentingSheet(PresentingSheet)
    case presentingSheetConfirming(PresentingSheetConfirming)
    case pendingNavigation(PendingNavigation)
    case maintenance(Maintenance)

    @PhaseSet([
        Browsing.self, Confirming.self, PresentingSheet.self, PresentingSheetConfirming.self, PendingNavigation.self,
    ])
    fileprivate enum PrivateAllNav {}

    public enum Input: Sendable {
        case selectList(Int?)
        case presentSheet(String)
        case confirm(String)
        case confirmOnSheet(String)
        case navigate(String)
        case enterMaintenance(String)
        case leaveMaintenance
    }

    @Transition(from: PrivateAllNav.self, on: Input.selectList)
    fileprivate static func selectList<Source: PrivateSelectionCarrying>(
        _ source: Source,
        _ id: Int?
    ) -> Source {
        var next = source
        next.selectedListID = id
        return next
    }

    @Transition(from: PrivateAllNav.self, on: Input.presentSheet)
    fileprivate static func presentSheet<Source: PrivateSelectionCarrying>(
        _ source: Source,
        _ sheet: String
    ) -> PresentingSheet {
        PresentingSheet(sheet: sheet, selectedListID: source.selectedListID)
    }

    @Transition(on: Input.confirm)
    fileprivate static func confirm(_ source: Browsing, _ prompt: String) -> Confirming {
        Confirming(prompt: prompt, selectedListID: source.selectedListID)
    }

    @Transition(on: Input.confirmOnSheet)
    fileprivate static func confirmOnSheet(_ source: PresentingSheet, _ prompt: String) -> PresentingSheetConfirming {
        PresentingSheetConfirming(prompt: prompt, sheet: source.sheet, selectedListID: source.selectedListID)
    }

    @Transition(from: [Browsing.self, Confirming.self], on: Input.navigate)
    fileprivate static func navigate<Source: PrivateSelectionCarrying>(
        _ source: Source,
        _ destination: String
    ) -> PendingNavigation {
        PendingNavigation(destination: destination, selectedListID: source.selectedListID)
    }

    @Transition(on: Input.enterMaintenance)
    fileprivate static func enterMaintenance(_ source: Browsing, _ reason: String) -> Maintenance {
        Maintenance(reason: reason)
    }

    @Transition(on: Input.leaveMaintenance)
    fileprivate static func leaveMaintenance(_ source: Maintenance) -> Browsing {
        Browsing()
    }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum ComposedPublicFlow: Sendable {
    public struct StageA: Sendable, PrivateTagged {
        public let tag: Int
        public var note: String
        public init(tag: Int = 1, note: String = "") {
            self.tag = tag
            self.note = note
        }
    }
    public struct StageB: Sendable, PrivateTagged {
        public let tag: Int
        public var note: String
        public init(tag: Int, note: String) {
            self.tag = tag
            self.note = note
        }
    }
    public struct Done: Sendable { public let total: Int }

    @Initial case stageA(StageA = StageA())
    case stageB(StageB)
    @Terminal case done(Done)

    public enum Input: Sendable {
        case advance
        case decide(Bool)
    }

    @Transition(on: Input.advance)
    fileprivate static func advance(_ source: StageA) -> StageB {
        StageB(tag: source.tag, note: source.note)
    }

    @Transition(from: [StageA.self, StageB.self], on: Input.decide)
    fileprivate static func keep<Source: PrivateTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed note: String
    )
        -> Source
    {
        var next = source
        next.note = note
        return next
    }

    @Transition(from: [StageA.self, StageB.self], on: Input.decide)
    fileprivate static func finish<Source: PrivateTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed delta: Int
    ) -> Done {
        Done(total: source.tag + delta)
    }

    @Route(on: Input.decide)
    fileprivate static func routeDecide(_ source: StageA, _ finishNow: Bool) -> Route.RouteDecide {
        finishNow ? .finish(1) : .keep("a")
    }

    @Route(on: Input.decide)
    fileprivate static func routeDecide(_ source: StageB, _ finishNow: Bool) -> Route.RouteDecide {
        finishNow ? .finish(2) : .keep("b")
    }
}

@StateMachine(mode: .ownedOnly)
public nonisolated enum DocPublicFlow: ~Copyable {
    public struct Draft: ~Copyable, PrivateUniqueTitled {
        public var title: String
        public init(title: String) { self.title = title }
    }
    public struct Review: ~Copyable, PrivateUniqueTitled {
        public var title: String
        public init(title: String) { self.title = title }
    }
    public enum RenameFailure: Error, Sendable { case empty }

    @Initial case draft(Draft)
    case review(Review)

    public enum Input {
        case submit
        case rename(String)
    }

    @Transition(on: Input.submit)
    fileprivate static func submit(_ source: consuming Draft) -> Review {
        Review(title: source.title)
    }

    @Transition(from: [Draft.self, Review.self], on: Input.rename)
    fileprivate static func rename<Source: PrivateUniqueTitled & ~Copyable>(
        _ source: consuming Source,
        _ title: String
    ) -> Advance<Source, Source, Never, RenameFailure> {
        guard !title.isEmpty else { return .rejected(.empty, source) }
        var next = source
        next.title = title
        return .advanced(next, effects: [])
    }
}
