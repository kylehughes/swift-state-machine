# Worked examples

Read larger graphs in the repository's example target.

The repository's `Sources/StateMachineExamples` target holds worked examples
that are larger than the ones in these articles. The package's tests, compiler
fixtures, and iOS check app use them, and no product publishes them, so read
them in the source tree rather than importing them. Each file is one
self-contained workflow.

## Macro-declared graphs

- `GeneratedProfile.swift` loads a profile with two operations under a load
  scope that also requires an authentication scope, revokes a running load when
  authentication changes, retries and refreshes, and restores saved data
  through a function that rejects an interrupted load.
- `GeneratedTransfers.swift` downloads files with a keyed operation, so each
  file's download is its own work. Cancelling a file revokes only its work,
  going offline revokes every download, completion edges read the key from the
  request their work started with, and a `Logged` event carries a line for the
  app's log.
- `GeneratedRetry.swift` routes one input to two edges through a router that can
  decline it, so a typed call and `send` both run the same router, and marks
  both destinations `@Terminal`.
- `GeneratedScreen.swift` routes an operation's result through a router that can
  decline it, so delivery and the owned method both run the same router. Its
  operation takes no input, and its inheritance clause lists `Equatable`, so its
  effects compare in another module.
- `GeneratedNote.swift` declares an isolated schema whose payloads and results
  are not `Sendable`, for a `MainActorHost` or an `IsolatedHost`.

## Generated owners and raw runtime

- `ProfileEditor.swift` wraps a presentation over a `MainActor` host for one
  screen, with named load, refresh, retry, cancel, and account-change actions.
- [`SerializedPipeline.swift`](https://github.com/kylehughes/swift-state-machine/blob/main/Sources/StateMachineExamples/SerializedPipeline.swift)
  declares an isolated `Local`-only two-stage pipeline (`Detect` into `Render`,
  emitting `Notice` milestones ahead of starts) and a `@MainActor` runner that
  serializes uncooperative off-main-actor work into one running task and one
  latest-pending closure, preserving exact-handle acknowledgment and FIFO
  reentrant callbacks.
- `IsolatedNote.swift` is a handwritten editor with non-`Sendable` value data,
  built directly on the raw runtime, with owned, local, and `MainActor` forms.
- `ReferenceProfile.swift` is the handwritten form of the profile graph, built
  directly on the raw runtime.
- `ReferenceProfileArchive.swift` adds a versioned archive that validates
  decoded data, migrates its legacy format, and rejects interrupted loading.
- `OwnedResource.swift` carries a noncopyable resource through a consuming edge
  that returns the original owner on rejection.
- `ValueWorkflow.swift` shows an owned workflow over ordinary value data that
  returns two ordered effect descriptions.

## Supporting files for the profile workflows

- `ProfileValues.swift` holds the validated request and response values the
  profile workflows share.
- `ProfileNetwork.swift` holds a `URLSession` driver and a controllable fake
  that ignores cancellation until a test completes it.
