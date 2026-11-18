# Save and restore profile data

Persist validated model data and create new authority when it is restored.

Neither form of the profile graph can restore a loading phase: the interrupted
request has no live execution to resume. The application can reject an
interrupted request or map it to a resting phase when creating the archive or
validating it for restoration. ``GeneratedProfile`` declares restoration with
the schema macro and is the shortest path. ``ReferenceProfile`` is the
handwritten form of the same graph, and its versioned
``ReferenceProfile/Archive`` is the fuller example of encoding, decoding, and
migration.

## Restore a generated owner

``GeneratedProfile`` declares an ``GeneratedProfile/Archive`` of ordinary data
and one function marked `@Restoration` that validates it. The function returns
the generated `Restoration`, which has a case for each phase in which no
operation is active: `idle`, `loaded`, and `failed`. It rejects a saved loading
phase with ``GeneratedProfile/RestoreRejection``.

Declaring the function gives every generated owner except `Owned` an
`init(restoring:)` that mirrors its ordinary initializer and throws exactly when
the function does. This example builds an archive from a snapshot's model and
restores an owner from it:

```swift
import StateMachineExamples

func archive(of model: GeneratedProfile) -> GeneratedProfile.Archive {
    switch model {
    case .idle(let idle): .idle(idle.userID)
    case .loading(let loading): .loading(loading.request)
    case .loaded(let loaded): .loaded(loaded.profile)
    case .failed(let failed): .failed(failed.request, failed.failure)
    }
}

func restoreGeneratedProfile(
    _ archive: GeneratedProfile.Archive,
    drivers: GeneratedProfile.Drivers
) throws(GeneratedProfile.RestoreRejection) -> GeneratedProfile.Shared {
    try GeneratedProfile.Shared(restoring: archive, drivers: drivers)
}
```

Restoring `archive(of: owner.snapshot().model)` forks an owner: it copies
validated data into an independent owner at revision zero and starts no tasks. A
snapshot taken while the profile was loading produces a `.loading` archive, and
`restoreGeneratedProfile` throws `.interruptedLoading` for it. The restored
owner has fresh authority. An observation, completion, or proposal from the
original owner cannot authorize work on it.

A phase with running work has no case in `Restoration`, so returning one from
the function does not compile. The function either rejects that saved shape, as
`GeneratedProfile` does, or maps it to a resting phase. To resume a saved
request instead of rejecting it, map `.loading(let request)` to
`.idle(Idle(userID: request.userID))`, restore, and send `.load(request)` to
start a fresh fetch.

The archive is ordinary data, and its encoding is the application's choice.
`UserID` and `ProfileRequest` validate their values during decoding. `Profile`
uses synthesized decoding, which calls the checked decoder for its `userID`
field. No live ticket, observation provenance, prepared transition, or task is
part of it.

## Encode a historical snapshot

``ReferenceProfile/Archive`` stores a model and its presentation field. It
cannot store a loading phase. Idle, loaded, and failed models can be archived.
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
`presentation`. An explicit `version` of 0 and an omitted `version` field both
select version 0. Its `model` and `presentation` fields have the same shape as
in version 1. Both forms pass through the same validation and encode as
version 1.

Decoding checks the version before reading the model payload. An unsupported
integer version throws `Archive.DecodingRejection.unsupportedVersion`.
Malformed versions, including an explicit `null`, fail decoding. Nested
`UserID` and `ProfileRequest` values use their checked decoders, and a loading
model throws `RestoreRejection.interruptedLoading`. A malformed or invalid
archive never becomes a live owner.

## Choose a new owner or reset the current one

| Operation | Authority and history |
| --- | --- |
| `init(restoring:)` on a generated owner | Creates an independent owner at revision zero from data that the `@Restoration` function validated. It starts no tasks. |
| `Local.restore` or `Shared.restore` on `ReferenceProfile` | Creates an independent owner at revision zero from validated data. Shared restoration requires its immutable drivers. |
| `fork()` on `ReferenceProfile` | Copies persistable current data into an independent owner at revision zero. It starts no tasks and rejects loading. |
| `reset(_:expected:)` on `ReferenceProfile` | Attempts a new incarnation against the expected current snapshot. It preserves the owner's increasing revision and revokes old work authority. |

An observation or completion from the original owner cannot authorize work on
a restored or forked owner. Reset also invalidates proposals and completions
from its preceding incarnation. A revoked worker may still be running until it
cooperatively finishes; resetting data does not establish physical termination.
