# Schema evolution for record_sync_journal (round 3)

Status: round 3, after two 4/4 RECAST strikes (`TEMPER.md`). Nothing here is built.
Earlier rounds: `DESIGN-round1.md` (holding, carrying), `DESIGN-round2.md`.
Code: `proto/` (copies of `lib/src`). Shelf facts: `proto/b2_shelf_excerpt.md`.

## The idea in one paragraph

Two app versions may disagree only about *whole* families and units, never
about what an existing unit holds. An old build leaves out what it can't read,
says so, and never writes there, so its `kills` and `saw` only ever name writes
it saw. Nothing is kept on the device that the device can't read. The shelf
already keeps every write. After an upgrade, the device reads the shelf again
from the start and doesn't count the upgrade as done until it has finished.

## Preconditions (ship gates)

1. **codraw's B2 states two sentences**: "The shelf never deletes a publisher's
   entries; a full sub-quota refuses the POST and leaves history." And "Every
   envelope sent live is also posted to the shelf." Today B2 evicts nothing and
   seals, persists and then sends (`proto/b2_shelf_excerpt.md` §2.3, §3.1),
   but it promises neither.
2. **The package ships §2 (skip-on-read) before either app releases this
   package to users.** A build without it throws when a newer tab writes a new
   unit into a shared store. Once every shipped build skips, that can't happen.
3. **Engram** is covered only when engram's transport has a log it can read
   again. Until engram's session confirms that, engram's mixed versions are out
   of scope.

## 1. The freeze

What an app may change between versions:

- **May add:** a family (with its record type), or a unit to an existing type.
  A new record type always comes with a new family, so a family's `resolve` is
  frozen whole.
- **May never change, once a version that declares it has shipped:**
  - a unit's field set (adding a field counts as a change);
  - a field's encoding: codec, scale, what absence means;
  - a unit's write-once bit;
  - a family's name, identity fields, key derivation, `resolve`, and
    `allowsDeterministicBirth`;
  - a record type's name.
- **Never remove, rename, or reuse a deprecated name.** Deprecate instead:
  still declared, no longer written.
- **The package is frozen too.** Every byte string a shipped v=1 door admitted
  stays admissible, and the meanings of `kills`, `saw`, ghost and contest stay
  fixed. A tighter door or a different set function needs a new wire `v`,
  with its own design.

`SchemaSnapshot.of(families, resolveVectors)` writes a canonical snapshot of
everything above that the package can see, and `snapshot.isFrozenBy(families)`
checks the new families only add to it. Each app commits its last shipped
snapshot and asserts this in a test, and keeps codec fixtures (bytes → value)
beside it. **The check can't see:** codecs, or `resolve` on identities outside
the vectors. The README says so.

## 2. Reads leave out what this build can't read, and say so

- `Refusal` gains `unknownVersion` (split out of `schema` for `v != 1`).
  `Refusal.isNewerSchema` is true for `unknownFamily`, `unknownUnit` and
  `unknownVersion` only. Under the freeze, those are the only refusals a newer
  build's writes can cause.
- On a stored write, a refusal where `isNewerSchema` is true means it is left
  out. **Any other refusal still throws `StateError`**: it means the freeze was
  broken or the store is corrupt, and that should be loud.
- `read` returns a sealed result: `Readable(RecordView)`, or
  `UnreadRecord(id, unread)` when every stored write was left out, or null only
  when nothing is stored. An editor can never mistake "written by a newer
  version" for "absent", and won't create a record on top of one.
- `RecordView.unread` and `UnreadRecord.unread` hold `UnreadWrite` values: a
  distinct type that `UnitWriteDraft` doesn't accept, so a left-out id can
  never be copied into `kills` or `saw`.
- `readAll` returns both kinds.
- `recompute` stays strict. Any refusal throws inside the transaction and
  nothing lands, so an old tab can never rebuild a newer tab's writes away.
  Nothing calls it automatically.

## 3. After an upgrade, the shelf is read again, and the upgrade isn't done until that finishes

The package can't run this, because transport belongs to the app. It is the
contract an app's transport must keep, and the README states it:

- On a version change, the transport records `replayPending(version)` durably
  *before* reading anything.
- It reads every publisher's log from the start and absorbs each frame.
  Absorbing is idempotent, so an interrupted replay can resume from a saved
  per-publisher page cursor or simply start over.
- It clears `replayPending` only after every publisher's log, as listed when the
  replay began, has been absorbed to its head. A crash leaves the flag set, so
  the next start resumes.
- Replay is single-flight per store. Several codraw tabs coordinate through the
  same lock the store's transactions take, so a second tab waits or skips.
- Each device waits a random interval before replaying, so release morning
  isn't every device on page zero at once.
- Writing during a replay is allowed. A write made before the replay finishes
  acts on part of history. When the rest arrives, the overlap shows as a
  contest or a ghost, exactly as for any device that was offline.
- An app may count newer-schema refusals by distinct (family, unit) and ask the
  user to update. It never stores the frames.

## What was deleted, and stays deleted

Holding writes on the device, carrying unknown fields, the held index, the
fingerprint trigger, the held-bytes cap. `JournalStore` gains nothing.

## Named tradeoffs

- **Each upgrade downloads everything again.** Owner: the app's transport.
  Accepted because it is the only route that repairs earlier drops.
- **A stale tab sees less, and is told so**, until reloaded. Owner: app UI.
- **An old device's delete leaves a ghost on a record a newer device extended.**
  The delete really didn't see the newer unit. A device that knows the unit
  settles it by deleting again. Owner: app ghost UI.
- **The freeze is permanent.** A unit that turns out to need a field becomes a
  new unit, and the old one is deprecated. Owner: each app's schema authors.

## Questions for the strike (last round)

1. With the preconditions met, is there a path on which a device that can read a
   write never comes to hold it?
2. Is there a path on which `kills` or `saw` names a write its author didn't see?
3. Does skip-or-throw split stored refusals correctly under the freeze?
