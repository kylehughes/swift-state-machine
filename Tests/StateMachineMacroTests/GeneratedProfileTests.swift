import StateMachine
import StateMachineExamples
import Testing

@Suite struct GeneratedProfileTests {
    private enum Failure: Error { case unexpected }
    private func begin(_ owner: inout GeneratedProfile.Local) throws -> GeneratedProfile.FetchWork {
        guard case .idle(let idle) = owner.snapshot(),
            case .committed = owner.commit(try idle.begin(.init(userID: idle.value.userID))),
            let batch = owner.drainCommands(limit: 1).first,
            case .fetch(let work) = batch.commands.first
        else { throw Failure.unexpected }
        return work
    }
    @Test func distinctOperationsIssueCorrectTypedWorkAndRetireIndependently() throws {
        let user = try UserID("kyle")
        var owner = GeneratedProfile.Local(.init(userID: user))
        let fetch = try begin(&owner)
        guard case .loading(let loading) = owner.snapshot(),
            case .committed = owner.commit(try loading.audit("record")),
            case .audit(let audit) = owner.drainCommands(limit: 1).first?.commands.first
        else { throw Failure.unexpected }
        #expect(audit.input == "record")
        guard case .committed = owner.deliver(.audit(audit.succeeded(Profile(userID: user, name: "Audit")))) else {
            throw Failure.unexpected
        }
        let acknowledgment1230 = owner.acknowledgeExecution(audit.execution, disposition: .terminated)
        #expect(acknowledgment1230 == .recorded)
        guard case .committed = owner.deliver(.fetch(fetch.succeeded(Profile(userID: user, name: "Typed")))) else {
            throw Failure.unexpected
        }
        let acknowledgment1493 = owner.acknowledgeExecution(fetch.execution, disposition: .terminated)
        #expect(acknowledgment1493 == .recorded)
        guard case .loaded(let loaded) = owner.snapshot() else { throw Failure.unexpected }
        #expect(loaded.value.profile.name == "Typed")
        guard case .stale = owner.deliver(.fetch(fetch.failed(.unavailable))) else { throw Failure.unexpected }
    }
    @Test func dependencyInvalidationRejectsAnOtherwiseCurrentSealedCompletion() throws {
        let user = try UserID("kyle")
        var owner = GeneratedProfile.Local(.init(userID: user))
        let fetch = try begin(&owner)
        guard case .loading(let before) = owner.snapshot(),
            case .success(let preparedOutcome) = fetch.succeeded(Profile(userID: user, name: "Prepared"))
        else { throw Failure.unexpected }
        let preparedBeforeRevocation = try before.received(preparedOutcome)
        guard case .loading(let loading) = owner.snapshot(),
            case .committed = owner.commit(try loading.authenticationChanged()),
            case .loading(let current) = owner.snapshot()
        else { throw Failure.unexpected }
        guard case .rejected(.inactiveAuthority, _) = owner.commit(preparedBeforeRevocation) else {
            throw Failure.unexpected
        }
        let completion = fetch.succeeded(Profile(userID: user, name: "Stale"))
        guard case .success(let outcome) = completion else { throw Failure.unexpected }
        guard case .rejected(.inactiveAuthority, _) = owner.commit(try current.received(outcome)) else {
            throw Failure.unexpected
        }
        let acknowledgment2648 = owner.acknowledgeExecution(fetch.execution, disposition: .terminated)
        #expect(acknowledgment2648 == .recorded)
        _ = owner.close()
        _ = owner.drainCommands(limit: 20)
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }
    @Test func foreignOwnersRejectGeneratedHistoricalAuthority() throws {
        let user = try UserID("kyle")
        var first = GeneratedProfile.Local(.init(userID: user))
        var second = GeneratedProfile.Local(.init(userID: user))
        guard case .idle(let idle) = first.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.foreignOwner, _) = second.commit(try idle.begin(.init(userID: user))) else {
            throw Failure.unexpected
        }
        #expect(first.snapshot().ordinal == 0)
        _ = first.close()
    }
    @Test func managedGeneratedDriverCompletesAndJoins() async throws {
        let user = try UserID("kyle")
        let network = ControlledProfileNetwork()
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: .init(
                fetch: { await network.drivers.fetch($0) },
                audit: { _ in .success(Profile(userID: user, name: "Audit")) }
            )
        )
        let (snapshots, events) = AsyncStream<GeneratedProfile.Snapshot>.makeStream()
        let token = try owner.subscribe { events.yield($0) }
        defer {
            token.cancel()
            events.finish()
        }
        guard case .idle(let idle) = owner.snapshot(),
            case .committed(let receipt) = owner.commit(try idle.begin(.init(userID: user)))
        else {
            throw Failure.unexpected
        }
        let request = await network.nextRequest()
        #expect(await owner.flush(through: receipt))
        guard case .loading = owner.snapshot() else { throw Failure.unexpected }
        #expect(await network.complete(request.id, with: .success(.init(userID: user, name: "Managed"))))
        var iterator = snapshots.makeAsyncIterator()
        while let snapshot = await iterator.next() {
            if case .loaded(let loaded) = snapshot {
                #expect(loaded.value.profile.name == "Managed")
                break
            }
        }
        await owner.shutdown()
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }
    @Test func handwrittenSecondOperationIssuesDistinctAcceptedWork() throws {
        let user = try UserID("kyle")
        var owner = ReferenceProfile.Local(.init(userID: user))
        guard case .idle(let idle) = owner.snapshot(),
            case .committed = owner.commit(try idle.load(.init(userID: user)))
        else {
            throw Failure.unexpected
        }
        guard case .start(let fetch) = owner.drainCommands(limit: 1).first?.commands.first,
            case .loading(let loading) = owner.snapshot(), case .committed = owner.commit(try loading.audit("audit")),
            case .audit(let audit) = owner.drainCommands(limit: 1).first?.commands.first
        else { throw Failure.unexpected }
        guard case .committed = owner.deliver(.audit(audit.succeeded(Profile(userID: user, name: "Audit")))) else {
            throw Failure.unexpected
        }
        let acknowledgment5536 = owner.acknowledgeExecution(audit.execution, disposition: .terminated)
        #expect(acknowledgment5536 == .recorded)
        guard case .committed = owner.deliver(.fetch(fetch.succeeded(.init(userID: user, name: "Handwritten")))) else {
            throw Failure.unexpected
        }
        let acknowledgment5803 = owner.acknowledgeExecution(fetch.execution, disposition: .terminated)
        #expect(acknowledgment5803 == .recorded)
    }
}

extension GeneratedProfileTests {
    @Test func generatedManagedCancellationRetainsPhysicalExecutionUntilReturn() async throws {
        let user = try UserID("kyle")
        let network = ControlledProfileNetwork()
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: .init(fetch: { await network.drivers.fetch($0) }, audit: { _ in .failure(.unavailable) }),
            configuration: try .init(executions: 1)
        )
        guard case .idle(let idle) = owner.snapshot(),
            case .committed(let receipt) = owner.commit(try idle.begin(.init(userID: user)))
        else { throw Failure.unexpected }
        let request = await network.nextRequest()
        #expect(await owner.flush(through: receipt))
        let terminal = owner.close()
        #expect(await owner.flush(through: terminal))
        #expect(!owner.isQuiescent)
        #expect(await network.inFlightCount == 1)
        #expect(await network.complete(request.id, with: .success(.init(userID: user, name: "Late"))))
        await owner.shutdown()
        #expect(owner.isQuiescent)
        guard case .loading = owner.snapshot() else { throw Failure.unexpected }
    }
}

private final class WeakGeneratedOwner {
    weak var value: GeneratedProfile.Shared?
    init(_ value: GeneratedProfile.Shared) { self.value = value }
}

extension GeneratedProfileTests {
    @Test func retainedSubscriptionAndSnapshotDoNotOwnTheGeneratedFacade() throws {
        func make() throws -> (RuntimeSubscription, GeneratedProfile.Snapshot, WeakGeneratedOwner) {
            let user = try UserID("kyle")
            let owner = GeneratedProfile.Shared(
                .init(userID: user),
                drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
            )
            let token = try owner.subscribe { _ in }
            return (token, owner.snapshot(), WeakGeneratedOwner(owner))
        }
        let retained = try make()
        withExtendedLifetime(retained) {
            #expect(retained.2.value == nil)
        }
    }
}

extension GeneratedProfileTests {
    @Test(arguments: [false, true])
    func cancellationAndPreparedCompletionRespectBothSerialOrders(completionFirst: Bool) throws {
        let user = try UserID("kyle")
        var owner = GeneratedProfile.Local(.init(userID: user))
        let work = try begin(&owner)
        guard case .loading(let loading) = owner.snapshot(),
            case .success(let outcome) = work.succeeded(Profile(userID: user, name: "Result"))
        else { throw Failure.unexpected }
        let terminal = try loading.received(outcome)
        let cancellation = try loading.cancel()
        if completionFirst {
            guard case .committed = owner.commit(terminal), case .rejected(.conflict, _) = owner.commit(cancellation),
                case .loaded = owner.snapshot()
            else { throw Failure.unexpected }
        } else {
            guard case .committed = owner.commit(cancellation),
                case .rejected(.inactiveAuthority, _) = owner.commit(terminal), case .idle = owner.snapshot()
            else { throw Failure.unexpected }
        }
        let acknowledgment = owner.acknowledgeExecution(work.execution, disposition: .terminated)
        #expect(acknowledgment == .recorded)
        _ = owner.close()
        _ = owner.drainCommands(limit: 20)
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }
}

extension GeneratedProfileTests {
    @Test func generatedManagedSubscriptionDefaultIs128AndConfiguredBoundsAreValidated() throws {
        #expect(GeneratedProfile.Configuration.default.subscriberCapacity == 128)
        #expect(GeneratedProfile.Configuration.default.limits.commits == 256)
        #expect(GeneratedProfile.Configuration.default.limits.descriptors == 64)
        #expect(GeneratedProfile.Configuration.default.limits.executions == 256)
        #expect(throws: RuntimeLimits.Failure.nonpositiveCapacity) {
            _ = try GeneratedProfile.Configuration(subscribers: 0)
        }
        let user = try UserID("kyle")
        let drivers = GeneratedProfile.Drivers(
            fetch: { _ in .failure(.unavailable) },
            audit: { _ in .failure(.unavailable) }
        )
        let owner = GeneratedProfile.Shared(.init(userID: user), drivers: drivers)
        var tokens: [RuntimeSubscription] = []
        for _ in 0 ..< 128 { tokens.append(try owner.subscribe { _ in }) }
        do {
            _ = try owner.subscribe { _ in }
            Issue.record("Default subscription bound exceeded")
        } catch { guard case .capacityExceeded = error else { throw Failure.unexpected } }
        tokens.removeLast().cancel()
        tokens.append(try owner.subscribe { _ in })
        for token in tokens { token.cancel() }
        let one = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: drivers,
            configuration: try .init(subscribers: 1)
        )
        let token = try one.subscribe { _ in }
        do {
            _ = try one.subscribe { _ in }
            Issue.record("Configured subscription bound exceeded")
        } catch { guard case .capacityExceeded = error else { throw Failure.unexpected } }
        token.cancel()
        _ = owner.close()
        _ = one.close()
    }
}
