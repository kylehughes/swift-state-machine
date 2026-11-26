import Foundation
import StateMachine

/// Compact nine-phase `.isolated`, `.local` fixture with nested nontrivial payloads and one
/// observable operation so every generated wrapper type (`Snapshot`, `Receipt`, `CommitResult`,
/// `CommandBatch`, `DeliveryResult`, `DiscardResult`, `Prepared`, `Local`) remains live.
@StateMachine(mode: .isolated, owners: [.local])
nonisolated enum DocumentSyncFlow {
    /// Non-Sendable reference-backed token confined to the owner's isolation domain.
    final class Lease {
        let label: String
        var sequence: UInt64
        init(label: String, sequence: UInt64) {
            self.label = label
            self.sequence = sequence
        }
    }

    enum Detail {
        case local(id: String, branch: String, notes: [String])
        case remote(etag: String, endpoint: URL, headers: [String: String])
        case merged(base: String, heads: [String], metadata: [String: String])
    }

    enum FailureReason: Error {
        case network(host: String, detail: String, hints: [String])
        case conflict(expected: Detail, actual: Detail, note: String)
    }

    struct Envelope {
        var documentID: String
        var title: String
        var endpoint: URL
        var detail: Detail
        var tags: [String]
        var attributes: [String: String]
        var lease: Lease
    }

    // MARK: - Nine Distinct Nominal Phases

    struct Idle {
        var envelope: Envelope
        var note: String
        var pendingTags: [String]
        var extra: [String: String]
    }
    struct Preparing {
        var envelope: Envelope
        var detail: Detail
        var checks: [String]
        var startedBy: String
    }
    struct Queued {
        var envelope: Envelope
        var queueName: String
        var destination: URL
        var headers: [String: String]
    }
    struct Running {
        var envelope: Envelope
        var detail: Detail
        var workerID: String
        var activeHeaders: [String: String]
    }
    struct Verifying {
        var envelope: Envelope
        var remoteDetail: Detail
        var digests: [String: String]
        var unresolved: Set<String>
    }
    struct Reviewing {
        var envelope: Envelope
        var reviewers: [String]
        var comments: [String: [String]]
        var summary: String?
    }
    struct Publishing {
        var envelope: Envelope
        var channel: String
        var mirrorURL: URL
        var receipts: [String: String]
    }
    struct Degraded {
        var envelope: Envelope
        var reason: FailureReason
        var prior: [FailureReason]
        var hints: [String: String]
    }
    struct Archived {
        var envelope: Envelope
        var archiveURL: URL
        var finalDetail: Detail
        var sealNotes: [String]
    }

    @Initial case idle(Idle)
    case preparing(Preparing)
    case queued(Queued)
    case running(Running)
    case verifying(Verifying)
    case reviewing(Reviewing)
    case publishing(Publishing)
    case degraded(Degraded)
    @Terminal case archived(Archived)

    enum Scope {
        @Active(in: [Running.self])
        case work
        case session
    }

    @Operation(scope: Scope.work, requires: [Scope.session], admission: .latest)
    enum Process {
        typealias Input = Envelope
        typealias Output = Detail
        typealias Failure = FailureReason
    }

    enum Input {
        case annotate(String)
        case prepare(String)
        case enqueue(URL)
        case start(String)
        case advanceReview(String)
        case approvePublish(URL)
        case finishPublish(Detail)
        case recover(String)
        case archive(URL)
    }

    @Transition(on: Input.annotate)
    fileprivate static func annotate(_ source: Idle, _ tag: String) -> Idle {
        var next = source
        next.pendingTags.append(tag)
        next.extra["last"] = tag
        return next
    }

    @Transition(on: Input.prepare)
    fileprivate static func beginPrepare(_ source: Idle, _ actor: String) -> Preparing {
        Preparing(
            envelope: source.envelope,
            detail: source.envelope.detail,
            checks: source.pendingTags,
            startedBy: actor
        )
    }

    @Transition(on: Input.enqueue)
    fileprivate static func enqueueWork(_ source: Preparing, _ url: URL) -> Queued {
        Queued(
            envelope: source.envelope,
            queueName: source.startedBy,
            destination: url,
            headers: ["x-actor": source.startedBy]
        )
    }

    @Transition(on: Input.start, starts: [Process.self])
    fileprivate static func startWork(_ source: Queued, _ workerID: String) -> Change<Running, Effect.StartWork> {
        let running = Running(
            envelope: source.envelope,
            detail: source.envelope.detail,
            workerID: workerID,
            activeHeaders: source.headers
        )
        return Change(running, effects: [.process(source.envelope)])
    }

    @Transition(onSuccess: Process.self)
    fileprivate static func workSucceeded(_ source: Running, _ output: Process.Output) -> Verifying {
        Verifying(
            envelope: source.envelope,
            remoteDetail: output,
            digests: source.activeHeaders,
            unresolved: [source.workerID]
        )
    }

    @Transition(onFailure: Process.self)
    fileprivate static func workFailed(_ source: Running, _ failure: Process.Failure) -> Degraded {
        Degraded(envelope: source.envelope, reason: failure, prior: [failure], hints: ["worker": source.workerID])
    }

    @Transition(on: Input.advanceReview)
    fileprivate static func enterReview(_ source: Verifying, _ reviewer: String) -> Reviewing {
        var env = source.envelope
        env.detail = source.remoteDetail
        return Reviewing(
            envelope: env,
            reviewers: [reviewer],
            comments: ["verify": Array(source.unresolved)],
            summary: reviewer
        )
    }

    @Transition(on: Input.approvePublish)
    fileprivate static func beginPublish(_ source: Reviewing, _ mirrorURL: URL) -> Publishing {
        Publishing(
            envelope: source.envelope,
            channel: source.reviewers.first ?? "default",
            mirrorURL: mirrorURL,
            receipts: ["reviewer": source.summary ?? "none"]
        )
    }

    @Transition(on: Input.finishPublish)
    fileprivate static func finishPublish(_ source: Publishing, _ detail: Detail) -> Idle {
        var env = source.envelope
        env.detail = detail
        return Idle(envelope: env, note: source.channel, pendingTags: [], extra: source.receipts)
    }

    @Transition(on: Input.recover)
    fileprivate static func recover(_ source: Degraded, _ note: String) -> Idle {
        Idle(envelope: source.envelope, note: note, pendingTags: [], extra: source.hints)
    }

    @Transition(on: Input.archive)
    fileprivate static func archive(_ source: Idle, _ url: URL) -> Archived {
        Archived(
            envelope: source.envelope,
            archiveURL: url,
            finalDetail: source.envelope.detail,
            sealNotes: source.pendingTags
        )
    }
}
