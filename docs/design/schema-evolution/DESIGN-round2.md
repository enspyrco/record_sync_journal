# Schema evolution for record_sync_journal (round 2)

Status: round 2, after a 4/4 RECAST strike (`TEMPER.md`). Nothing here is built.
Round 1 is `DESIGN-round1.md`. The code is in `proto/` (copies of `lib/src`).

## What changed from round 1

Round 1 kept every well-formed write on the device ("held"), carried unknown
fields, and checked that schemas only grew. The strike found:

- carrying lets an old editor kill data it never saw;
- held writes break deduplication (`holds` reads the projection only);
- old and new tabs on one store fight over one projection;
- the junk cap reopens the hole it closes.

All four flaws come from keeping a second copy of bytes the shelf already keeps.
So round 2 deletes holding and carrying, and moves the repair to the place that
already has every write.

## Context (unchanged facts)

- A write is canonical JSON bytes; its id is their SHA-256. Bytes are never
  rewritten.
- `Door.admit` checks wire shape, then the app's schema. A refused write is not
  stored.
- Every read puts the stored bytes through the current door again (`_readmit`),
  and today a refusal throws `StateError`. `readAll` throws if any record's
  write is refused.
- `unsent()` returns only writes authored here. Devices don't relay.
- **The shelf** (codraw's B2 DESIGN, branch `docs/canvas-sync-order-authority`):
  - §3.1: "GET serves the paged per-publisher index and entries by id."
  - §2.4/C7: the shelf "holds bytes and decides nothing semantic".
  - §2.5: a reader "reads every publisher's log anyway".
  - Nothing in B2 evicts an entry. Volume is bounded by per-publisher
    sub-quotas (§3.5).
  - So every write is on the shelf as opaque bytes and can be read again.
- codraw's store is shared by many tabs, and a tab can run an older build than
  its neighbour for as long as it stays open.

## The design

### 1. The schema freeze (the rule; holds regardless of the rest)

What an app may change between versions:

- **May add:** a family; a record type; a unit to an existing type.
- **May never change, once a version that declares it has shipped:**
  - a unit's field set. Adding a field to an existing unit is forbidden too:
    new data goes in a new unit;
  - a field's encoding (codec, scale, meaning of absence);
  - a unit's write-once bit;
  - a family's name, identity fields, key derivation, `IdentityFamily.resolve`
    behaviour on any identity it accepted, and `allowsDeterministicBirth`;
  - a record type's name.
- **May never remove or rename** anything above. Deprecate instead: keep it
  declared, stop writing it.
- **May never reuse** a deprecated name for something else.
- The wire `v` stays 1. A new wire version needs a design of its own.

Why freezing unit field sets is the load-bearing rule: with it, two versions
only ever disagree about *whole* units, families and types. A device never
writes a unit it doesn't know, so it never kills a write whose fields it
couldn't see. `kills` keeps meaning "I saw this and replace it."

**What the package checks.** `SchemaSnapshot.of(families)` produces a
canonical JSON snapshot: family names, identity fields, deterministic birth,
types, units, field sets and write-once bits. It includes resolve vectors the
app supplies (identity → key and type). `snapshot.isFrozenBy(families)` is
true when the new families keep everything the snapshot holds and only add.
Each app commits its last shipped snapshot and asserts this in a test.

**What it can't check:** field codecs and the meaning of a field, which live in
app code. The app keeps codec fixtures (bytes → value) beside the snapshot.
`resolve` on identities outside the vectors is the same story. The README
says this in those words.

### 2. Reads skip what their door doesn't admit

- `read` and `readAll` never throw on a stored write. A write the current door
  refuses is left out of the view.
- The view says what it left out: `RecordView.unread` is the set of write ids
  skipped. `readAll` also returns records whose every write was skipped, as a
  new `UnreadRecord(id, unread)`. An app can say "a newer version wrote here"
  rather than show nothing.
- Under the freeze, a skipped write is a whole unit or family this build doesn't
  know. The device can't write it, so its blind spot never turns into a kill.
- **`recompute` stays strict**: a refusal throws inside the transaction, so
  nothing lands. An old tab can never rebuild a newer tab's writes away. It
  fails loudly instead, and the app's answer is "reload this tab".

### 3. After an upgrade, read the shelf again from the start

- This is the transport's job, and it is mandatory. On the first start of a new
  app version, the transport reads every publisher's log from the beginning and
  absorbs each frame. A frame already held returns `AlreadyHeld` and costs a
  door pass (https://github.com/enspyrco/record_sync_journal/issues/5 caches
  that).
- It also repairs what earlier builds dropped, including builds already
  deployed. Holding writes on the device could never do that.
- The package makes the cue visible. `Refusal` gains `unknownVersion` (split out
  of `schema` for `v != 1`). `Refusal.isNewerSchema` is true for
  `unknownFamily`, `unknownUnit` and `unknownVersion`. An app can count these
  per publisher and prompt the user to update. It never stores them.
- A device that keeps a per-publisher page cursor may advance it past a refused
  frame: the frame stays on the shelf, and the next upgrade reads it again.

### 4. What is deleted from round 1

The `Held` result, the wire/schema split as two admission levels, carrying
unknown fields, the held index, the fingerprint trigger, the held-bytes cap and
publisher gate. `JournalStore` gains nothing, so the stores codraw and engram
are writing against `761228f` stay the contract.

## Cost and named tradeoffs

- **Each upgrade downloads everything again.** That's proportional to the
  canvas's shelf size, and it happens once per app version. Owner: the app's
  transport. Accepted because it is the only path that repairs earlier drops.
  If it becomes too slow, a per-family "first seen at page N" cursor can narrow
  it later without changing this package.
- **A stale tab sees less than a fresh one** until reloaded, and is told so
  (`unread`). Owner: the app's UI.
- **Retention is assumed, not promised.** B2 doesn't evict, but it doesn't say
  "never evicts" either. Owner: codraw's B2 design. One line there makes this
  safe: "the shelf never deletes a publisher's entries." Until then it's a
  dependency, named here.
- **An old device's delete leaves a ghost on a record a newer device has
  extended.** Its `saw` can't name a write to a unit it doesn't know, so the
  record is drawn as a ghost until a device that knows the unit deletes it
  again. That is the model being honest, since the delete really didn't see the
  edit, but it will happen on every mixed-version delete of an extended record.
  Owner: the app's ghost UI. The alternative, letting a delete ignore units its
  author can't see, would let a delete hide data it never witnessed.
- **Engram's transport is unchecked.** Whether engram has a replayable store of
  every write is a question for engram's session. If it doesn't, this design
  doesn't cover engram's mixed versions, and engram must either get one or
  refuse to sync across versions (alternative C, for engram only).

## Questions for the strike

1. Does freezing unit field sets close the kill-of-unseen-data hole on every
   path, including deletes (`saw` from an old device can't name a write from an
   unknown unit, so would the record become a ghost)?
2. Is skip-on-read plus strict `recompute` safe on a shared multi-tab store?
3. Does reading the shelf again after an upgrade have a failure mode that
   holding didn't (partial replay, crash mid-replay, quota)?
4. Is anything still missing from the freeze list?
