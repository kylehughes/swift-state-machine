import StateMachine
import StateMachineSchema
import Testing
import os

@StateMachine(mode: .shared)
nonisolated private enum OwnedValueContract: Sendable {
    struct Ready: Sendable {
        let identifier: Int
        let history: [String: [Int]]
    }
    struct Finished: Sendable, Equatable {
        let identifier: Int
        let history: [String: [Int]]
        let label: String
    }
    @Initial case ready(Ready)
    case finished(Finished)
    enum Scope { case effects }
    enum Input: Sendable {
        case finish(String)
        case checked(String)
        case silent
    }
    enum Rejection: Error { case emptyLabel }
    @Operation(scope: Scope.effects, activeIn: [Finished.self], admission: .latest)
    enum Audit {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.effects, activeIn: [Finished.self], admission: .latest)
    enum Publish {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    @Transition(on: Input.finish, starts: [Audit.self, Publish.self])
    fileprivate static func finish(_ source: Ready, _ label: String) -> Change<Finished, Effect.Finish> {
        Change(
            Finished(identifier: source.identifier, history: source.history, label: label),
            effects: [.audit(source.identifier), .publish(label)]
        )
    }
    @Transition(on: Input.checked, starts: [Audit.self, Publish.self])
    fileprivate static func checked(
        _ source: Ready,
        _ label: String
    ) throws(Rejection) -> Change<Finished, Effect.Checked> {
        guard !label.isEmpty else { throw .emptyLabel }
        return Change(
            Finished(identifier: source.identifier, history: source.history, label: label),
            effects: [.audit(source.identifier), .publish(label)]
        )
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Finished, _ output: Audit.Output) -> Finished {
        source
    }
    @Transition(onSuccess: Publish.self)
    fileprivate static func published(
        _ source: Finished,
        _ output: Publish.Output
    ) -> Finished {
        source
    }
    @Transition(on: Input.silent)
    fileprivate static func silent(_ source: Ready) -> Finished {
        Finished(identifier: source.identifier, history: source.history, label: "silent")
    }
}

extension OwnedValueContract.Effect: Equatable {}

@StateMachine(mode: .ownedOnly)
nonisolated private enum OwnedResourceContract: ~Copyable {
    struct Resource: ~Copyable {
        let identifier: Int
        let release: @Sendable (Int) -> Void
        deinit { release(identifier) }
    }
    struct Ready: ~Copyable {
        let resource: Resource
        let history: [String: [Int]]
    }
    struct Finished: ~Copyable {
        let resource: Resource
        let history: [String: [Int]]
        let label: String
    }
    @Initial case ready(Ready)
    case finished(Finished)
    enum Scope { case effects }
    enum Input { case finish(String) }
    enum Rejection: Error { case emptyLabel }
    @Operation(scope: Scope.effects, activeIn: [Finished.self], admission: .latest)
    enum Audit {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.effects, activeIn: [Finished.self], admission: .latest)
    enum Publish {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(
        _ source: consuming Finished,
        _ output: Audit.Output
    ) -> Advance<Finished, Finished, Never, Never> {
        .advanced(source, effects: [])
    }
    @Transition(onSuccess: Publish.self)
    fileprivate static func published(
        _ source: consuming Finished,
        _ output: Publish.Output
    ) -> Advance<Finished, Finished, Never, Never> {
        .advanced(source, effects: [])
    }
    @Transition(on: Input.finish, starts: [Audit.self, Publish.self])
    fileprivate static func finish(
        _ source: consuming Ready,
        _ label: String
    ) -> Advance<Ready, Finished, Effect.Finish, Rejection> {
        guard !label.isEmpty else { return .rejected(.emptyLabel, source) }
        let identifier = source.resource.identifier
        return .advanced(
            Finished(resource: source.resource, history: source.history, label: label),
            effects: [.audit(identifier), .publish(label)]
        )
    }
}

extension OwnedResourceContract.Effect: Equatable {}

@Suite struct OwnedResultContractTests {
    @Test func generatedSharedSuccessPreservesCompleteResult_RT037() async {
        let executions = OSAllocatedUnfairLock(initialState: [String]())
        let drivers = OwnedValueContract.Drivers(
            audit: { identifier in
                executions.withLock { $0.append("audit:\(identifier)") }
                return .success(identifier)
            },
            publish: { label in
                executions.withLock { $0.append("publish:\(label)") }
                return .success(label)
            }
        )
        let owner = OwnedValueContract.owned(.init(identifier: 17, history: ["before": [2, 5]]))
        #expect(executions.withLock { $0 }.isEmpty)
        let result = owner.finish("published")
        #expect(
            result.next.withValue { $0 }
                == OwnedValueContract.Finished(identifier: 17, history: ["before": [2, 5]], label: "published")
        )
        #expect(result.effects.map(\.effect) == [.audit(17), .publish("published")])
        #expect(executions.withLock { $0 }.isEmpty)
        for effect in result.effects {
            switch effect {
            case .audit(let identifier): _ = await drivers.audit(identifier)
            case .publish(let label): _ = await drivers.publish(label)
            }
        }
        #expect(executions.withLock { $0 } == ["audit:17", "publish:published"])
    }

    @Test func generatedSharedTypedRecoveryPreservesCompleteResult_RT037() {
        let owner = OwnedValueContract.owned(.init(identifier: 23, history: ["original": [8, 13]]))
        switch owner.checked("") {
        case .advanced: Issue.record("Empty label accepted")
        case .rejected(.emptyLabel, let original):
            #expect(original.withValue { $0.identifier } == 23)
            #expect(original.withValue { $0.history } == ["original": [8, 13]])
            switch original.checked("recovered") {
            case .advanced(let next, let effects):
                #expect(
                    next.withValue { $0 }
                        == OwnedValueContract.Finished(
                            identifier: 23,
                            history: ["original": [8, 13]],
                            label: "recovered"
                        )
                )
                #expect(effects.map(\.effect) == [.audit(23), .publish("recovered")])
            case .rejected: Issue.record("Recovered predecessor rejected valid input")
            }
        }
    }

    @Test func generatedSharedEmptySuccessPreservesDestination_RT037() {
        let owner = OwnedValueContract.owned(.init(identifier: 31, history: ["empty": []]))
        let finished = owner.silent()
        #expect(
            finished.withValue { $0 }
                == OwnedValueContract.Finished(identifier: 31, history: ["empty": []], label: "silent")
        )
    }

    @Test(arguments: [false, true])
    func generatedUniqueSuccessAndRecoveryPreserveResource_RT009_RT037(rejectFirst: Bool) {
        let releases = OSAllocatedUnfairLock(initialState: [Int]())
        let executions = OSAllocatedUnfairLock(initialState: [String]())
        do {
            let resource = OwnedResourceContract.Resource(identifier: 41) { identifier in
                releases.withLock { $0.append(identifier) }
            }
            let owner = OwnedResourceContract.owned(.init(resource: resource, history: ["retained": [3, 7]]))
            let accepted:
                Advance<
                    OwnedResourceContract.Owned<OwnedResourceContract.Ready>,
                    OwnedResourceContract.Owned<OwnedResourceContract.Finished>,
                    OwnedResourceContract.Effect.Finish, OwnedResourceContract.Rejection
                >
            if rejectFirst {
                switch owner.finish("") {
                case .advanced:
                    Issue.record("Empty label accepted")
                    return
                case .rejected(.emptyLabel, let original):
                    #expect(original.withValue { $0.resource.identifier } == 41)
                    #expect(original.withValue { $0.history } == ["retained": [3, 7]])
                    #expect(releases.withLock { $0 }.isEmpty)
                    #expect(executions.withLock { $0 }.isEmpty)
                    accepted = original.finish("complete")
                }
            } else {
                accepted = owner.finish("complete")
            }
            switch consume accepted {
            case .advanced(let next, let effects):
                #expect(next.withValue { $0.resource.identifier } == 41)
                #expect(next.withValue { $0.history } == ["retained": [3, 7]])
                #expect(next.withValue { $0.label } == "complete")
                #expect(effects.map(\.effect) == [.audit(41), .publish("complete")])
                #expect(releases.withLock { $0 }.isEmpty)
                #expect(executions.withLock { $0 }.isEmpty)
                for effect in effects {
                    switch effect {
                    case .audit(let identifier): executions.withLock { $0.append("audit:\(identifier)") }
                    case .publish(let label): executions.withLock { $0.append("publish:\(label)") }
                    }
                }
                #expect(executions.withLock { $0 } == ["audit:41", "publish:complete"])
            case .rejected: Issue.record("Valid finish rejected")
            }
        }
        #expect(releases.withLock { $0 } == [41])
        #expect(executions.withLock { $0 } == ["audit:41", "publish:complete"])
    }

    @Test func generatedUniqueRejectedPredecessorDisposesOnceWithoutEffects_RT009_RT037() {
        let releases = OSAllocatedUnfairLock(initialState: [Int]())
        let executions = OSAllocatedUnfairLock(initialState: [String]())
        do {
            let resource = OwnedResourceContract.Resource(identifier: 53) { identifier in
                releases.withLock { $0.append(identifier) }
            }
            let owner = OwnedResourceContract.owned(.init(resource: resource, history: ["original": [11]]))
            switch owner.finish("") {
            case .advanced: Issue.record("Empty label accepted")
            case .rejected(.emptyLabel, let original):
                #expect(original.withValue { $0.resource.identifier } == 53)
                #expect(original.withValue { $0.history } == ["original": [11]])
                #expect(releases.withLock { $0 }.isEmpty)
                #expect(executions.withLock { $0 }.isEmpty)
            }
        }
        #expect(releases.withLock { $0 } == [53])
        #expect(executions.withLock { $0 }.isEmpty)
    }
}
