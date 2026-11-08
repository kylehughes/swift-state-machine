import Foundation
import StateMachineExamples
import Testing

@Suite struct ProfileArchiveTests {
    typealias Flow = ReferenceProfile

    private func decode(_ json: String) throws -> Flow.Archive {
        try JSONDecoder().decode(Flow.Archive.self, from: Data(json.utf8))
    }

    @Test func currentRoundTripEmitsOnlyVersionedData_RT033() throws {
        let id = try UserID("kyle")
        let models: [Flow.Model] = [
            .idle(.init(userID: id)),
            .loaded(.init(profile: .init(userID: id, name: "Kyle"))),
            .failed(.init(request: try .init(userID: id, attempts: 5), failure: .unavailable)),
        ]
        for model in models {
            let archive = try Flow.Archive(model: model, presentation: "profile")
            let data = try JSONEncoder().encode(archive)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys) == ["version", "model", "presentation"])
            #expect(object["version"] as? Int == 1)
            #expect(Flow.Archive.currentVersion == 1)
            let restored = try JSONDecoder().decode(Flow.Archive.self, from: data)
            #expect(restored.model == model)
            #expect(restored.presentation == "profile")
        }
    }

    @Test(arguments: ["", "\"version\":0,"])
    func legacyDataMigratesToCurrentVersion_RT033(version: String) throws {
        // Fixed historical payloads, independent of the current encoder.
        let archive = try decode(
            """
            {\(version)"model":{"idle":{"_0":{"userID":"kyle"}}},"presentation":"legacy"}
            """
        )
        #expect(archive.model == .idle(.init(userID: try UserID("kyle"))))
        #expect(archive.presentation == "legacy")
        let data = try JSONEncoder().encode(archive)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
    }

    @Test(arguments: [-1, 2, 999])
    func unknownVersionPrecedesInvalidPayload_RT033(version: Int) {
        #expect(throws: Flow.Archive.DecodingRejection.unsupportedVersion(version)) {
            try decode("{\"version\":\(version),\"model\":false,\"presentation\":0}")
        }
    }

    @Test(arguments: ["null", "true", "\"1\"", "1.5", "[]", "{}"])
    func malformedVersionPrecedesMissingPayload_RT033(version: String) {
        do {
            _ = try decode("{\"version\":\(version)}")
            Issue.record("Malformed version decoded")
        } catch DecodingError.typeMismatch(_, let context) {
            #expect(context.codingPath.map(\.stringValue) == ["version"])
        } catch DecodingError.valueNotFound(_, let context) {
            #expect(context.codingPath.map(\.stringValue) == ["version"])
        } catch DecodingError.dataCorrupted {
            // Foundation reports an unrepresentable fractional Int as data corruption.
            #expect(version == "1.5")
        } catch {
            Issue.record("Unexpected version failure: \(error)")
        }
    }

    @Test(arguments: [
        "not JSON",
        "[]",
        "{\"version\":1}",
        "{\"version\":1,\"model\":{\"unknown\":{}},\"presentation\":\"\"}",
        "{\"version\":1,\"model\":{\"idle\":{\"_0\":{}}},\"presentation\":\"\"}",
        "{\"version\":1,\"model\":{\"idle\":{\"_0\":{\"userID\":\"kyle\"}}},\"presentation\":42}",
    ])
    func malformedPayloadIsRejected_RT033(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test(arguments: ["", "bad id"])
    func decodingValidatesNestedUserID_RT033(identifier: String) {
        #expect(throws: UserID.ValidationFailure.self) {
            try decode(
                """
                {"version":1,"model":{"idle":{"_0":{"userID":"\(identifier)"}}},"presentation":""}
                """
            )
        }
    }

    @Test(arguments: [0, 6])
    func decodingValidatesNestedAttempts_RT033(attempts: Int) {
        #expect(throws: ProfileRequest.ValidationFailure.self) {
            try decode(
                """
                {"version":1,"model":{"failed":{"_0":{"request":{"userID":"kyle","attempts":\(attempts)},
                "failure":"unavailable"}}},"presentation":""}
                """
            )
        }
    }

    @Test(arguments: ["", "\"version\":0,", "\"version\":1,"])
    func decodingRejectsInterruptedLoading_RT033(version: String) {
        #expect(throws: Flow.RestoreRejection.self) {
            try decode(
                """
                {\(version)"model":{"loading":{"_0":{"request":{"userID":"kyle","attempts":1}}}},
                "presentation":""}
                """
            )
        }
    }

    @Test func ordinaryArchiveAndForkRejectLoading_RT033() throws {
        let id = try UserID("kyle")
        let request = try ProfileRequest(userID: id)
        #expect(throws: Flow.RestoreRejection.self) {
            try Flow.Archive(model: .loading(.init(request: request)))
        }
        var local = Flow.Local(.init(userID: id))
        guard case .idle(let idle) = local.snapshot(),
            case .committed = local.commit(try idle.load(request))
        else {
            Issue.record("Could not enter loading")
            return
        }
        do {
            _ = try local.fork()
            Issue.record("Loading owner forked")
        } catch Flow.RestoreRejection.interruptedLoading {
        }
    }

    @Test func decodedRestoreAndForkRejectOriginalProofs_RT033() throws {
        var original = Flow.Local(.init(userID: try UserID("kyle")))
        guard case .committed = original.commit(original.snapshot().presentationChanged("saved")) else {
            Issue.record("Presentation edit rejected")
            return
        }
        let old = original.snapshot()
        let archive = try JSONDecoder()
            .decode(
                Flow.Archive.self,
                from: JSONEncoder().encode(Flow.Archive(model: old.model, presentation: old.presentation))
            )
        var restored = Flow.Local.restore(archive)
        var fork = try original.fork()
        #expect(restored.snapshot().ordinal == 0)
        #expect(fork.snapshot().ordinal == 0)
        #expect(restored.snapshot().model == old.model)
        #expect(restored.snapshot().presentation == "saved")
        guard case .rejected(.foreignOwner, _) = restored.commit(old.presentationChanged("foreign")),
            case .rejected(.foreignOwner, _) = fork.commit(old.presentationChanged("foreign")),
            case .committed = restored.commit(restored.snapshot().presentationChanged("fresh")),
            case .committed = fork.commit(fork.snapshot().presentationChanged("fresh"))
        else {
            Issue.record("Restore or fork adopted old authority or rejected fresh authority")
            return
        }
    }

    @Test func resetInvalidatesIssuedCompletionWithoutResettingOrdinal_RT033() throws {
        let id = try UserID("kyle")
        var local = Flow.Local(.init(userID: id))
        guard case .idle(let idle) = local.snapshot(),
            case .committed = local.commit(try idle.load(ProfileRequest(userID: id)))
        else {
            Issue.record("Could not start work")
            return
        }
        let batches = local.drainCommands(limit: 1)
        guard let batch = batches.first, case .start(let work) = batch.commands.first,
            case .loading(let loading) = local.snapshot(),
            case .success(let completion) = work.succeeded(Profile(userID: id, name: "Kyle"))
        else {
            Issue.record("Missing issued work")
            return
        }
        let candidate = try loading.received(completion)
        let archive = try Flow.Archive(model: .idle(.init(userID: id)))
        guard case .committed(let receipt) = local.reset(archive, expected: local.snapshot()) else {
            Issue.record("Reset rejected")
            return
        }
        #expect(receipt.ordinal == 2)
        guard case .rejected(.obsoleteIncarnation, _) = local.commit(candidate),
            case .committed(let next) = local.commit(local.snapshot().presentationChanged("fresh"))
        else {
            Issue.record("Reset retained old authority or rejected its new owner proof")
            return
        }
        #expect(next.ordinal == 3)
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        _ = local.close()
        _ = local.drainCommands(limit: 10)
        let quiescent = local.isQuiescent
        #expect(quiescent)
    }
}
