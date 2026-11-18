import StateMachine
import StateMachineExamples
import Testing

@Suite struct ManagedProfileTests {
    private let user = try! UserID("kyle")
    private func start(_ owner: ReferenceProfile.Shared) throws -> ReferenceProfile.Receipt {
        guard case .idle(let idle) = owner.snapshot(),
            case .committed(let receipt) = owner.commit(try idle.load(ProfileRequest(userID: user)))
        else { throw TestFailure.unexpectedState }
        return receipt
    }
    private enum TestFailure: Error { case unexpectedState }

    @Test func immediateCompletionIsRegisteredAndJoined_RT021() async throws {
        let profile = Profile(userID: user, name: "Immediate")
        let owner = ReferenceProfile.Shared(
            .init(userID: user),
            drivers: .init(fetch: { _ in .success(profile) }, audit: { _ in .failure(.unavailable) })
        )
        let (snapshots, events) = AsyncStream<ReferenceProfile.Snapshot>.makeStream()
        let token = try owner.subscribe { events.yield($0) }
        defer {
            token.cancel()
            events.finish()
        }
        let receipt = try start(owner)
        #expect(await owner.flush(through: receipt) == .processed)
        var iterator = snapshots.makeAsyncIterator()
        while let snapshot = await iterator.next() {
            if case .loaded(let loaded) = snapshot {
                #expect(loaded.value.profile == profile)
                break
            }
        }
        #expect(owner.pendingCompletions().isEmpty)
        #expect(await owner.shutdown() == .quiescent)
        #expect(owner.isQuiescent)
    }

    @Test func cancellationInsensitiveDriverRemainsOwnedUntilActualReturn_RT018_RT029() async throws {
        let network = ControlledProfileNetwork()
        let owner = ReferenceProfile.Shared(
            .init(userID: user),
            drivers: network.drivers,
            configuration: try .init(executionCapacity: 1)
        )
        let receipt = try start(owner)
        let request = await network.nextRequest()
        #expect(await owner.flush(through: receipt) == .processed)
        let close = owner.close()
        #expect(owner.close().revision == close.revision)
        #expect(await owner.flush(through: close) == .processed)
        #expect(await network.inFlightCount == 1)
        #expect(!owner.isQuiescent)
        guard case .timedOut(let diagnostics) = await owner.shutdown(deadline: .now) else {
            Issue.record("Cancellation-insensitive driver was reported terminated")
            return
        }
        #expect(diagnostics.outstanding.count == 1)
        #expect(diagnostics.outstanding.first?.disposition == .issued)
        #expect(diagnostics.outstanding.first?.preparation == nil)
        #expect(diagnostics.processedThrough == close.revision)
        #expect(await network.inFlightCount == 1)
        #expect(await network.complete(request.id, with: .success(Profile(userID: user, name: "Late"))))
        #expect(await owner.shutdown() == .quiescent)
        #expect(owner.snapshot().isClosed)
        guard case .loading = owner.snapshot() else {
            Issue.record("Stale result changed closed model")
            return
        }
    }

    @Test func authenticationScopeInvalidationDisposesLateOutcome_RT013_RT023() async throws {
        let network = ControlledProfileNetwork()
        let owner = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
        _ = try start(owner)
        let request = await network.nextRequest()
        guard case .committed(let invalidation) = owner.commit(owner.snapshot().authenticationChanged()) else {
            Issue.record("Invalidation rejected")
            return
        }
        #expect(await owner.flush(through: invalidation) == .processed)
        #expect(await network.complete(request.id, with: .failure(.unauthorized)))
        #expect(await owner.shutdown() == .quiescent)
        guard case .loading = owner.snapshot() else {
            Issue.record("Revoked outcome changed model")
            return
        }
        #expect(owner.pendingCompletions().isEmpty)
    }

    @Test func flushRejectsForeignReceiptAndDoesNotWaitForDriver_RT029() async throws {
        let network = ControlledProfileNetwork()
        let owner = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
        let foreign = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
        let receipt = try start(owner)
        let request = await network.nextRequest()
        #expect(await foreign.flush(through: receipt) == .foreignOwner)
        #expect(await owner.flush(through: receipt) == .processed)
        #expect(await network.inFlightCount == 1)
        #expect(await network.complete(request.id, with: .failure(.unavailable)))
        #expect(await owner.shutdown() == .quiescent)
        #expect(await foreign.shutdown() == .quiescent)
    }

    @Test func unrelatedPresentationSurvivesTypedFailureAndRetry_RT012_RT023() async throws {
        let network = ControlledProfileNetwork()
        let owner = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
        let (snapshots, events) = AsyncStream<ReferenceProfile.Snapshot>.makeStream()
        let token = try owner.subscribe { events.yield($0) }
        defer {
            token.cancel()
            events.finish()
        }
        _ = try start(owner)
        let first = await network.nextRequest()
        guard case .committed(let edit) = owner.commit(owner.snapshot().presentationChanged("Preserved")) else {
            Issue.record("Presentation rejected")
            return
        }
        #expect(await owner.flush(through: edit) == .processed)
        #expect(await network.complete(first.id, with: .failure(.unavailable)))
        var iterator = snapshots.makeAsyncIterator()
        var retried = false
        while let snapshot = await iterator.next() {
            if case .failed(let failed) = snapshot {
                #expect(failed.value.failure == .unavailable)
                #expect(snapshot.presentation == "Preserved")
                guard case .committed = owner.commit(failed.retry()) else {
                    Issue.record("Typed retry rejected")
                    return
                }
                retried = true
                break
            }
        }
        #expect(retried)
        let second = await network.nextRequest()
        #expect(second.id != first.id)
        #expect(await network.complete(second.id, with: .success(Profile(userID: user, name: "Retried"))))
        while let snapshot = await iterator.next() {
            if case .loaded(let loaded) = snapshot {
                #expect(loaded.value.profile.name == "Retried")
                #expect(snapshot.presentation == "Preserved")
                break
            }
        }
        #expect(owner.pendingCompletions().isEmpty)
        #expect(await owner.shutdown() == .quiescent)
    }

    @Test func localDeliveryKeepsExecutionAcknowledgmentSeparate() throws {
        var owner = ReferenceProfile.Local(.init(userID: user))
        guard case .idle(let idle) = owner.snapshot(),
            case .committed = owner.commit(try idle.load(ProfileRequest(userID: user))),
            let batch = owner.drainCommands(limit: 1).first,
            case .start(let work) = batch.commands.first
        else {
            Issue.record("Expected local work")
            return
        }
        guard case .committed = owner.deliver(.fetch(work.succeeded(Profile(userID: user, name: "Local")))) else {
            Issue.record("Local delivery rejected")
            return
        }
        #expect(owner.pendingCompletions().isEmpty)
        _ = owner.close()
        _ = owner.drainCommands(limit: 10)
        let awaitingExecution = owner.isQuiescent
        #expect(!awaitingExecution)
        #expect(owner.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        let settled = owner.isQuiescent
        #expect(settled)
        guard case .stale = owner.deliver(.fetch(work.failed(.unavailable))) else {
            Issue.record("Duplicate settled completion accepted")
            return
        }
    }

    @Test func thousandDeterministicManagedLifecyclesAndContention_RT030() async throws {
        let network = ControlledProfileNetwork()
        for index in 0 ..< 1_000 {
            let owner = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
            let token = try owner.subscribe { _ in }
            let receipt = try start(owner)
            let request = await network.nextRequest()
            #expect(await owner.flush(through: receipt) == .processed)
            if index.isMultiple(of: 2) { _ = owner.close() }
            token.cancel()
            #expect(await network.complete(request.id, with: .success(Profile(userID: user, name: "Cycle"))))
            #expect(await owner.shutdown() == .quiescent)
            #expect(await network.inFlightCount == 0)
        }
        // Writers contend on one actual managed owner while the fake driver is gated.
        let owner = ReferenceProfile.Shared(.init(userID: user), drivers: network.drivers)
        _ = try start(owner)
        let request = await network.nextRequest()
        await withTaskGroup(of: Void.self) { group in
            for writer in 0 ..< 8 {
                group.addTask {
                    for index in 0 ..< 250 {
                        while true {
                            let proposal = owner.snapshot().presentationChanged("\(writer)-\(index)")
                            switch owner.commit(proposal) {
                            case .committed: break
                            case .rejected(.conflict, _): continue
                            case .rejected(.capacityExceeded, _):
                                await Task.yield()
                                continue
                            case .rejected: Issue.record("Unexpected writer rejection")
                            }
                            break
                        }
                    }
                }
            }
        }
        #expect(owner.snapshot().revision == 2_001)
        #expect(await network.complete(request.id, with: .failure(.unavailable)))
        #expect(await owner.shutdown() == .quiescent)
        #expect(await network.inFlightCount == 0)
    }
}

#if os(macOS)
import Foundation

extension ManagedProfileTests {
    @Test func urlSessionAdapterExecutesOneLoopbackRequest_RT035() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-u", "-c",
            """
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    from urllib.parse import urlparse, parse_qs
                    parsed=urlparse(self.path)
                    assert parsed.path == '/profiles/'
                    assert parse_qs(parsed.query)['userID'] == ['../admin/a?b#c']
                    payload=b'{"userID":"../admin/a?b#c","name":"HTTP"}'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                def log_message(self, *args): pass
            server=HTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port, flush=True)
            server.handle_request()
            server.server_close()
            """,
        ]
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var portData = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else { throw TestFailure.unexpectedState }
            if byte == Data([10]) { break }
            portData.append(byte)
        }
        let port = try #require(String(data: portData, encoding: .utf8).flatMap(Int.init))
        let client = ProfileHTTPClient(baseURL: try #require(URL(string: "http://127.0.0.1:\(port)/profiles/")))
        let result = await client.drivers.fetch(try ProfileRequest(userID: try UserID("../admin/a?b#c")))
        guard case .success(let profile) = result else {
            Issue.record("URLSession adapter failed")
            return
        }
        #expect(profile == Profile(userID: try UserID("../admin/a?b#c"), name: "HTTP"))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
#endif
