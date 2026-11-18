# Worked examples

Read larger graphs in the repository's example target.

The repository's `Sources/StateMachineExamples` target holds worked examples
that are larger than the ones in these articles. The package's own tests use
them, and no product publishes them, so read them in the source tree rather than
importing them. Each file is one self-contained workflow:

- `GeneratedProfile.swift` loads a profile with two operations, an account scope
  that revokes a running load, a retry edge, and a restoration function that
  rejects an interrupted load.
- `GeneratedRetry.swift` routes one input to two edges through a router that can
  decline it, so a typed call and `send` both run the same router.
- `GeneratedScreen.swift` routes an operation's result through a router that can
  decline it, so delivery and the owned method both run the same router.
- `GeneratedNote.swift` declares an isolated schema whose payloads and results
  are not `Sendable`.
- `IsolatedNote.swift` is a handwritten editor with non-`Sendable` value data,
  built directly on the raw runtime, with owned, local, and `MainActor` forms.
- `ReferenceProfile.swift` is the handwritten form of the profile graph, built
  directly on the raw runtime.
- `ReferenceProfileArchive.swift` adds a versioned archive that validates
  decoded data, migrates its legacy format, and rejects interrupted loading.
- `ProfileEditor.swift` wraps a presentation over a `MainActor` host for one
  screen, with named load, retry, cancel, and account-change actions.
- `ProfileValues.swift` holds the validated request and response values the
  profile workflows share.
- `ProfileNetwork.swift` holds a URLSession driver and a controllable fake that
  ignores cancellation until a test completes it.
- `OwnedResource.swift` carries a noncopyable resource through a consuming edge
  that returns the original owner on rejection.
- `ValueWorkflow.swift` shows an owned workflow over ordinary value data that
  returns two ordered effect descriptions.
