# Save and restore data

Persist validated model data and create new authority when it is restored.

A saved value is ordinary data. It carries no live ticket, observation
provenance, prepared transition, or task, so restoring it never resumes work.
The schema declares how saved data becomes a phase, and every owner except
`Owned` can then be created from it with fresh authority at revision zero.

This article builds on one graph. A download is idle, running, or finished. Its
saved form, `Archive`, is its own `Codable` enum, so the application chooses
the encoding and the schema chooses what is allowed back in:

```swift
import Foundation
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Download: Sendable {
    struct Idle: Sendable { let name: String }
    struct Running: Sendable { let name: String }
    struct Finished: Sendable {
        let name: String
        let bytes: Int
    }

    enum Archive: Codable, Sendable {
        case idle(name: String)
        case running(name: String)
        case finished(name: String, bytes: Int)
    }

    enum RestoreRejection: Error, Sendable { case emptyName, negativeSize }

    @Initial case idle(Idle)
    case running(Running)
    case finished(Finished)

    enum Input: Sendable { case start, resume, cancel }

    @Operation(activeIn: [Running.self])
    enum Transfer {
        typealias Input = String
        typealias Output = Int
    }

    @Restoration(allows: [Running.self])
    fileprivate static func restore(_ saved: Archive) throws(RestoreRejection) -> Restoration {
        switch saved {
        case .idle(let name):
            guard !name.isEmpty else { throw .emptyName }
            return .idle(Idle(name: name))
        case .running(let name):
            guard !name.isEmpty else { throw .emptyName }
            return .running(Running(name: name))
        case .finished(let name, let bytes):
            guard !name.isEmpty else { throw .emptyName }
            guard bytes >= 0 else { throw .negativeSize }
            return .finished(Finished(name: name, bytes: bytes))
        }
    }

    @Transition(on: Input.start, starts: [Transfer.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(name: source.name), effects: [.transfer(source.name)])
    }

    @Transition(on: Input.resume, starts: [Transfer.self])
    fileprivate static func resume(_ source: Running) -> Change<Running, Effect.Resume> {
        Change(source, effects: [.transfer(source.name)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Running) -> Idle { Idle(name: source.name) }

    @Transition(onSuccess: Transfer.self)
    fileprivate static func received(_ source: Running, _ bytes: Transfer.Output) -> Finished {
        Finished(name: source.name, bytes: bytes)
    }
}
```

## Restore a schema's owner

A function marked `@Restoration` takes the saved data as its one unlabeled
parameter, which can be any type the application defines. It returns the
generated `Restoration` enum, and it may use typed `throws` to reject the data.
Declaring it gives `Local`, `Shared`, `ActorHost`, and `MainActorHost` an
`init(restoring:)` that mirrors the ordinary initializer, takes the saved data
in place of the initial payload, and throws exactly when the function does.
A managed owner's `init(restoring:)` also has the form with one driver closure
per operation:

```swift
func restoreDownload(
    _ archive: Download.Archive
) throws(Download.RestoreRejection) -> Download.Shared {
    try Download.Shared(restoring: archive, transferDriver: { name in name.count })
}
```

The restored owner starts at revision zero and starts no tasks. An observation,
completion, or proposal from any other owner cannot authorize work on it.

### Choose which phases restore

`Restoration` has a case for each phase in which no operation is active, and
nothing needs to list those phases. `idle` and `finished` are restorable here
for that reason. A phase in which an operation can be active is not restorable
by default, because saved data cannot resume running work. Returning one from
the validator does not compile. The compiler reports that `Download.Restoration`
has no member for that phase, and the author either rejects that saved shape or
maps it to a resting phase.

`@Restoration(allows: [Running.self])` lists phases where an operation can be
active that saved data may still restore. An owner restored into one holds no
outstanding work: restoring `Download.Archive.running(name: "Report")` shows
`running` at revision zero with nothing in flight, and the application sends an
input afterward, here `.resume`, to start fresh work. Allow a phase
only when it is a legitimate resting presentation of the user's intent and the
graph has an edge that leaves it.

The list also keeps the archive contract stable. If a later change makes an
operation active in a phase that restoration returns, the phase leaves
`Restoration` unless it is listed, and the validator stops compiling until the
author decides whether the archive still restores into it. A phase in which no
operation is active may be listed as well. Listing it pins it, so a later
operation that becomes active there leaves it restorable and the validator keeps
compiling.

## Fork an owner

Forking is restoring a saved copy of `snapshot.model`. A validator whose saved
type is the schema itself, as in `restore(_ saved: Self)`, forks in one
initializer call. With a separate archive type, convert the model first:

```swift
extension Download.Archive {
    init(_ model: Download) {
        switch model {
        case .idle(let idle): self = .idle(name: idle.name)
        case .running(let running): self = .running(name: running.name)
        case .finished(let finished): self = .finished(name: finished.name, bytes: finished.bytes)
        }
    }
}

func fork(_ original: Download.Shared) throws(Download.RestoreRejection) -> Download.Shared {
    try restoreDownload(Download.Archive(original.snapshot().model))
}
```

The fork copies validated data into an independent owner at revision zero. A
snapshot taken while the download was running forks into a `running` owner with
no work, which this validator allows. An observation, completion, or proposal
from the original owner cannot authorize work on the fork, so a presentation
for the fork is a new presentation: it starts a new revision history rather
than continuing the original's.

A generated owner has no in-place reset. To start over, restore or construct a
new owner and retire the old one with `close()` and `shutdown()`. A revoked
driver can still be running until it cooperatively finishes, because resetting
data does not establish physical termination.

## Encode and decode an archive

An archive is ordinary data, so any `Codable` encoding works. Build it from a
snapshot's `model` and use a standard encoder. Encoding records that revision's
data. It does not pause the original owner or reserve its current state, and
storage and durability are the caller's responsibility:

```swift
func encode(_ snapshot: Download.Snapshot) throws -> Data {
    try JSONEncoder().encode(Download.Archive(snapshot.model))
}

func restore(from data: Data) throws -> Download.Shared {
    let archive = try JSONDecoder().decode(Download.Archive.self, from: data)
    return try restoreDownload(archive)
}
```

Validation belongs in two places that do different jobs. Payload initializers
and `Decodable` conformances check each value as it is decoded, so a malformed
document fails before it reaches the owner. The `@Restoration` function checks
the relationships between values, such as which phase the data may enter. A
malformed or invalid archive never becomes a live owner.

## Version an archive and migrate old data

A stored format outlives the code that wrote it. Keep a version in the file and
read it before the payload, so the decoder can choose how to read the rest:

- Write the current version every time, whatever version was read.
- Treat a missing version as the earliest one you shipped.
- Reject a version you do not recognize with a typed error, and reject a
  malformed one, such as an explicit `null`, instead of guessing.
- Migrate an old shape to the current `Archive` in the decoder, then restore
  through the same `@Restoration` function, so one validation path covers every
  version.

This file type writes version 2, reads version 1 files that stored one name and
a finished flag, and treats a file with no version as version 1:

```swift
struct DownloadFile: Codable {
    enum DecodingRejection: Error { case unsupportedVersion(Int) }

    static let currentVersion = 2

    private enum CodingKeys: String, CodingKey { case version, archive, name, isFinished }

    let archive: Download.Archive

    init(_ archive: Download.Archive) { self.archive = archive }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        switch version {
        case 1:
            let name = try container.decode(String.self, forKey: .name)
            let isFinished = try container.decode(Bool.self, forKey: .isFinished)
            archive = isFinished ? .finished(name: name, bytes: 0) : .idle(name: name)
        case Self.currentVersion:
            archive = try container.decode(Download.Archive.self, forKey: .archive)
        default:
            throw DecodingRejection.unsupportedVersion(version)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(archive, forKey: .archive)
    }
}

func restoreFile(_ data: Data) throws -> Download.Shared {
    let file = try JSONDecoder().decode(DownloadFile.self, from: data)
    return try restoreDownload(file.archive)
}
```

Version 1 data restores into the same phases as version 2 data and encodes as
version 2 the next time it is saved.
