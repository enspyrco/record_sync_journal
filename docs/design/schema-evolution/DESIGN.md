# Schema evolution for record_sync_journal

Status: **UN-TEMPERED (provisional).** Three strikes, each 4/4 RECAST, and the
budget is spent (`TEMPER.md`). The core has held since round 1. This version
folds in round 3's findings and has not been struck. Nothing here is built.
Earlier rounds: `DESIGN-round1.md` (holding, carrying), `DESIGN-round2.md`,
`DESIGN-round3.md` (the version round 3 struck).
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
   envelope is posted to the shelf, and the POST acknowledged, before it is
   sent live; a refused POST, including one refused for a full sub-quota,
   leaves the author's entry unacknowledged in `unsent()`." Today B2 evicts
   nothing and seals, persists and then sends (`proto/b2_shelf_excerpt.md`
   §2.3, §3.1), but it promises neither, and it doesn't order the POST before
   the live send.
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

The package keeps a corpus to hold itself to that: every byte string in its
test vectors that a shipped door admitted, and fixtures for the meanings of
`kills`, `saw`, ghost and contest. A change that alters a verdict or a view
fails the package's own tests.

`SchemaSnapshot.of(families, resolveVectors)` writes a canonical snapshot of
everything above that the package can see, and `snapshot.isFrozenBy(families)`
checks the new families only add to it. Each app commits its last shipped
snapshot and asserts this in a test, and keeps codec fixtures (bytes → value)
beside it. **The check can't see:** codecs, or `resolve` on identities outside
the vectors. The README says so.

## 2. Reads leave out what this build can't read, and say so

- `Refusal` gains `unknownVersion`. **The door reads `v` before the v=1
  grammar**: after the object, depth, UTF-8 and canonical tests, an integer
  `v` other than 1 is `unknownVersion`, whatever other keys the frame has.
  Only a missing or non-integer `v`, or a v=1 frame that breaks the v=1
  grammar, is `schema`. Every future wire keeps `v` as an integer top-level
  key: that's the part of the wire that can never change. (Today the key-set
  test runs first, at `lib/src/unit_write.dart:350`, before `v` at line 358, so
  a future wire with a new key would refuse as `schema`.)
- `Refusal.isNewerSchema` is true for `unknownFamily`, `unknownUnit` and
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
- `readAll` returns both kinds, plus `UnreadableRecord(id, refusal)` for a
  record whose stored write throws, so one corrupt record doesn't take down the
  whole journal. `read` of that record still throws.
- `recompute` stays strict. Any refusal throws inside the transaction and
  nothing lands, so an old tab can never rebuild a newer tab's writes away.
  Nothing calls it automatically.

## 3. After an upgrade, the shelf is read again, and the upgrade isn't done until that finishes

The package can't run this, because transport belongs to the app. It is the
contract an app's transport must keep, and the README states it:

- On a version change, the transport records `replayPending(version)` durably
  *before* reading anything.
- **The replay has its own cursors**, one per publisher, starting at the
  beginning of each log. It never reads or resumes from the ordinary sync
  cursor, which went past refused frames during the mixed-version weeks. A
  crash resumes only from offsets this replay saved after `Appended` or
  `AlreadyHeld` under version N. Absorbing is idempotent, so starting over is
  always safe too.
- **Done means caught up after looking again**: list the publishers, read each
  log to an empty page, list the publishers again, and find no publisher and no
  page not yet read. Only then is `replayPending` cleared. A crash leaves it
  set, and the next start resumes.
- **More than one shelf**: the replay reads the union of every shelf, per
  publisher, and isn't done until every shelf has answered with an empty page.
  An entry acknowledged by one shelf is then found whenever that shelf is up;
  an outage delays the replay, and never shortens it. (codraw B2 acknowledges
  on at least one shelf, pending Nick's V8 ruling.)
- **One ordered log instead of per-publisher logs** (engram's Firestore
  `sync_log_v2`): one bookmark stands in for the per-publisher cursors. The
  bookmark is where a restart reads from, and reading carries on past it.
  It holds at the first frame `absorb` returns as `NotAdmitted` with
  `isNewerSchema`, so the upgraded build reads again from there, and a
  bookmark that moved past it would lose that frame for good. Any other
  `NotAdmitted` is a dead frame that no build will ever admit: the bookmark
  passes it, and the app may report it. Holding at a dead frame would hold
  the bookmark forever, and every restart would read the whole tail again.
- **Replay is single-flight through its own lock**, never the lock the store's
  transactions take. That lock isn't reentrant (codraw's `navigator.locks`),
  and replay opens a transaction for each frame it absorbs, so holding it would
  deadlock. On codraw this is a second `navigator.locks` name. A tab that finds
  the replay lock held waits, and only the holder clears the flag. A tab that
  dies releases the lock, and the next one resumes from the saved offsets.
- **The ordinary sync cursor is keyed by the build's schema snapshot id.** An
  older tab's progress past frames it refused never moves a newer build's
  cursor. A newer build's ordinary cursor starts where its replay finished.
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
- **An old build's view can look whole while a newer frame it refused exists.**
  That's the same state as any device that hasn't synced yet, and the model
  already shows the overlap when the frame arrives. Rejected on that basis
  (round 3, Tesla): a "full-view capability" that drafts would need. It would
  make a behind device read-only, which is the write gate round 2 rejected.
  The update prompt's count is the app's, and it may persist it.
- **Rejected (round 3, Noether): recording the replayed generation in the
  store, and deleting `recompute`.** The first is the round-1 fingerprint again.
  The "is this device short" state lives in the transport's durable
  `replayPending`, and `JournalStore` gains nothing. `recompute` stays as the
  repair tool: an old tab calling it throws, which is the point.
- **The freeze is permanent.** A unit that turns out to need a field becomes a
  new unit, and the old one is deprecated. Owner: each app's schema authors.

## Questions for the strike (last round)

1. With the preconditions met, is there a path on which a device that can read a
   write never comes to hold it?
2. Is there a path on which `kills` or `saw` names a write its author didn't see?
3. Does skip-or-throw split stored refusals correctly under the freeze?
