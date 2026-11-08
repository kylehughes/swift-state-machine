# Save and restore profile data

Persist validated model data and create new authority when it is restored.

``ReferenceProfile/Archive`` stores a model and its presentation field. It
cannot store a loading phase: the interrupted request has no live execution
to restore. Choose an application recovery state before creating the archive.
Idle, loaded, and failed models can be archived.

## Encode a historical snapshot

Create an archive from the snapshot's ordinary data, then use a standard
encoder:

```swift
import StateMachineExamples
import Foundation

func encodeProfile(_ snapshot: ReferenceProfile.Snapshot) throws -> Data {
    let archive = try ReferenceProfile.Archive(
        model: snapshot.model,
        presentation: snapshot.presentation
    )
    return try JSONEncoder().encode(archive)
}

func restoreProfile(_ data: Data) throws -> ReferenceProfile.Local {
    let archive = try JSONDecoder().decode(ReferenceProfile.Archive.self, from: data)
    return ReferenceProfile.Local.restore(archive)
}
```

Encoding a snapshot records that revision's data. It does not pause the original
owner or reserve its current state. Storage and durability are the caller's
responsibility. No live ticket, observation provenance, prepared transition, or
task appears in the archive.

## Decode and migrate before restoration

The encoder writes version 1 with the fields `version`, `model`, and
`presentation`. Version 0 uses the same model and presentation shape; a missing
version identifies that legacy format. Both legacy forms decode through the
current validation and encode back as version 1.

Decoding checks the version before reading the model payload. An unsupported
integer version throws `Archive.DecodingRejection.unsupportedVersion`.
Malformed versions, including an explicit `null`, fail decoding. Nested
`UserID` and `ProfileRequest` values use their checked decoders, and a loading
model throws `RestoreRejection.interruptedLoading`. A malformed or invalid
archive never becomes a live owner.

## Choose a new owner or reset the current one

| Operation | Authority and history |
| --- | --- |
| `Local.restore` or `Shared.restore` | Creates an independent owner at ordinal zero from validated data. Shared restoration requires its immutable drivers. |
| `fork()` | Copies persistable current data into an independent owner at ordinal zero. It starts no tasks and rejects loading. |
| `reset(_:expected:)` | Attempts a new incarnation against the expected current snapshot. It preserves the owner's increasing ordinal and revokes old work authority. |

An observation or completion from the original owner cannot authorize work on
a restored or forked owner. Reset also invalidates proposals and completions
from its preceding incarnation. A revoked worker may still be running until it
cooperatively finishes; resetting data does not establish physical termination.
