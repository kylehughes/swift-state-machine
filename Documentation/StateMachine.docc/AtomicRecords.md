# Install an immutable record

Use the raw storage primitive when implementing a runtime's admission boundary.

`AtomicRecordStorage` supports generated code and carries no source-stability
promise, like the other raw runtime types. Application code declares a graph
with the macros and does not need it.

``AtomicRecordStorage`` retains one immutable version behind a checked
`OSAllocatedUnfairLock`. Loading a version retains the whole record.
Installation succeeds only if the current version is identical to the expected
version.

```swift
import StateMachine

func replaceDraft() -> Bool {
    let storage = AtomicRecordStorage("Draft")
    let before = storage.load()
    let after = AtomicRecordStorage<String>.Version("Ready")
    return storage.install(after, replacing: before)
}
```

If another writer replaces `before` first, `install` returns `false`. The caller
must decide whether to read again, report a conflict, or discard its proposal.
Create a fresh `Version` for each proposed installation; deliberately
reinstalling an old version also reuses its comparison identity.

## Keep domain checks outside the primitive

The storage provides identity-checked replacement. It does not validate an
edge, issue operation authority, run an effect, or impose an operation policy.
A runtime computes a complete proposed record before calling `install`, then
uses the expected version to validate that its computation still applies.

A sealed domain facade privately owns its storage instance and versions. A
caller can create an independent raw store, but that store does not expose or
replace a facade's record. Do not publish a facade's storage as a convenience
for testing or customization.

## Preserve payload lifetime

The shared primitive requires `Copyable`, `Sendable` records. Extract the
immutable payload from a consumed public proposal before calling it. No caller
closure executes while the primitive holds its lock.

An accepted replacement retains the outgoing version through unlock. Failed
replacement also keeps its input versions alive through the locked comparison.
This lets final payload destruction occur outside the critical section. The
record still needs value semantics: storing a reference does not make its
referent immutable.
