# Data, ownership, and observations

Choose a representation by the authority the caller needs.

A model describes a phase. An owner can take a legal edge from that phase. An
observation records what a host contained at a particular revision. These have
different lifetimes, even when they expose the same payload.

| Representation | What it permits |
| --- | --- |
| Model or phase payload | Read, validate, encode, or construct ordinary data. |
| `Owned<Phase>` | Consume the current phase through an edge declared for that phase. |
| `Observed<Phase>` | Read a historical payload and prepare a declared edge. |
| `Prepared` | Attempt one admission of an inert proposal. |
| Work descriptor | Execute an accepted operation and seal its typed terminal outcome. |
| Receipt | Inspect the historical state accepted by a commit. |

## Transfer exclusive ownership

An owned workflow has one mutation capability. A consuming edge removes the
predecessor from the caller and returns the successor. This prevents a second
transition from the same owned value.

Recoverable rejection must return the original owner. ``Advance/rejected(_:_:)``
carries that owner with the typed failure; ``Advance/advanced(_:effects:)``
carries the complete successor and every effect in authored order. Dropping
either result disposes of the value it contains.

Switch on `.rejected(let failure, let original)` to inspect the error and retry
with the recovered owner, or `.advanced(let next, let effects)` to continue from
the successor. An infallible edge returns `Change`: retain its `effects`, then
pass its `next` to another consuming edge. That transfer does not permit using
the same successor again.

Effects are descriptions. Constructing ``Change`` or ``Advance`` does not
execute them. The caller or host decides when accepted work runs.

## Prepare from a historical observation

An observation remains valid as a historical value after the host changes. It
does not promise that its revision is still current. Preparing from it reads
that captured value and creates a noncopyable proposal without starting work.

Commit consumes the proposal and checks its owner, incarnation, authority, and
whole-root revision. The incarnation changes when an owner is reset, so
proposals from before the reset can no longer be committed. A rejection returns
the current observation so the caller can make a new decision. Copying an
observation does not create another owner, and a receipt does not reserve the
current state for later use.

## Keep construction separate from authority

Domain payload initializers validate data. Facade proof constructors remain
private or fileprivate. Live provenance, prepared transitions, and operation
capabilities are not persistence formats; restoration creates fresh authority
from validated data.

Shared payloads must satisfy both Swift's `Sendable` checking and the domain's
value-semantics contract. `Sendable` alone does not promise that a reference
points to an immutable historical value. Domain authors remain responsible for
validation, declared dependencies, and effect-free preparation. A driver's
sealed completion identifies its operation; it cannot prove the driver supplied
an honest result.

## Preserve value semantics under actor isolation

Actor confinement does not detach references when a payload is copied. This
example compiles, but its payload violates the historical-value contract:

```swift
@MainActor
final class TitleBox {
    var text = "Draft"
}

@MainActor
struct AliasedPhase {
    let title: TitleBox
}

@MainActor
func copiesStillAlias() -> Bool {
    let first = AliasedPhase(title: TitleBox())
    let second = first
    second.title.text = "Changed"
    return first.title.text == "Changed"  // true
}
```

Both accesses occur on the same actor, yet changing one copy changes what the
other copy observes. Store the `String` directly, retain immutable data, or
construct a detached value projection before recording a snapshot. Isolated
hosting removes the need to transfer every payload between actors; it does not
remove the value-semantics requirement.
