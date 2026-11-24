# Schema evolution for record_sync_journal

Status: proposal, for a design-temper strike. Nothing here is built.

## Context: what exists

`record_sync_journal` keeps records on a device as a log of whole field-group
("unit") writes. The code is in `proto/` beside this file (copies of `lib/src`).

- A write is canonical JSON bytes. Its id is SHA-256 of the bytes. Writes name
  the writes they replace (`kills`) and, for deletes, the content they witnessed
  (`saw`). Ids are evidence of having held a write, so **stored bytes can never
  be rewritten or migrated**: a changed byte is a different write that nobody
  killed.
- Every write enters through one `Door.admit(bytes)` (`proto/unit_write.dart`).
  It checks, in order: hash, first byte `{`, nesting depth ≤ 64, strict UTF-8,
  JSON, canonical re-encode, the wire keys and `v == 1`, sorted id lists, salt,
  then the app's schema: the identity's family must be known, the family must
  resolve the identity to a `RecordId` and a `RecordSchema`, the unit must be
  declared, every field must be declared in that unit, and write-once units
  refuse kills.
- `RecordId` is (family, key) and only the family can derive the key
  (`IdentityFamily.resolve`). **A write whose family this device does not know
  has no record id.**
- The journal (`proto/record_journal.dart`) has a log (every admitted write, by
  seq, with `authoredHere`) and a projection (each record's admitted write
  bytes). A view is a pure function of a record's projected writes.
- **Every read admits the stored bytes again, through the current door**
  (`_readmit`). A refusal there throws `StateError`. `recompute()` rebuilds the
  projection from the log through the same door.
- A refused write is not stored. `absorb` returns `NotAdmitted`.
- Transport is the app's. `unsent()` returns only writes authored here, so a
  device never relays what it absorbed. Writes travel through a shelf (codraw's
  B2 design: per-publisher storage that prices floods per publisher). Whether a
  device can fetch again from the shelf after an upgrade is up to the app's
  transport, and today nothing in this package asks for it.

Users: codraw (sembast store, web and mobile, many tabs) and engram (Drift
store). Both are about to pin `761228f`. Apps ship schema changes as app
updates, so devices on two schema versions sharing records is the normal case
for days or weeks, not an edge.

## The problem

What each kind of schema change does today:

| Change | Effect |
|---|---|
| Add a family, type, unit or field | Safe on the upgraded device. |
| Remove a field or unit | Old writes now fail the door. **Every read of that record throws.** |
| Rename a family or type | The id changes: a different record. Old data is orphaned. |
| Move a field between units | Breaks "a unit is written whole": old and new writes of the field don't kill each other. |
| Change a field's encoding (e.g. fixed-point scale) | Silently wrong values. |
| Make an existing unit write-once | Its old writes with kills fail the door; reads throw. |

And the worst one, **mixed versions**. A v2 device writes a field v1 doesn't
know (or a unit or family). v1's door refuses it, as `fields`, `unknownUnit` or
`unknownFamily`, and drops it. When v1 later upgrades, nothing sends that write
again: the transport has moved past it, and v1's peers don't relay. v1 and v2
now disagree about the record for good, and no error was ever raised. Writes
that kill the dropped write are a second casualty: v1 admits them, but their
`kills` name a write v1 never held, which is harmless for `live` but means v1's
view of the unit differs from v2's.

## Proposal

### 1. Split the door in two

- **Wire validity**, which needs no schema: hash, `{`, depth, strict UTF-8, JSON,
  canonical, wire keys, `v == 1`, id lists sorted and unique, salt shape, the
  `saw` rules that don't depend on the schema, and an identity that parses with
  a `family` string. This alone decides whether a write goes into the **log**.
- **Schema validity**: known family, resolvable identity, declared unit,
  declared fields, write-once, deterministic-birth permission. This decides
  whether a write goes into the **projection**.
- A wire-valid write that isn't schema-valid is **held**: it is in the log, not
  in the projection, and `absorb` returns a new `Held` result. It has no
  `RecordId` if its family is unknown, so it is indexed by write id only.
- `recompute()` (run after an app upgrade, or automatically when the families
  passed to the journal differ from the ones last recorded in the store)
  promotes every held write that the new door now admits.
- A read never throws. A stored write that the current door refuses is not
  projected; it is held. (So removing a unit makes its writes held, not fatal.)

### 2. Unknown fields in a known unit are carried, not refused

The door admits a content write to a declared unit whose `fields` include
undeclared names. The view exposes declared fields only. The write's bytes, and
so its id, its kills and the race semantics, are unchanged, so a v1 device
treats a v2 write to that unit as the live write it is. `_tomb` stays exact.

**Known flaw:** a unit is written whole. When v1 edits a unit, its new write
has no v2 field and kills the v2 write, so the v2 field's value is lost for
every device. Carrying makes the field *visible* to the race, not *safe* from
it. Options: (a) accept it and require new fields to go in new units ("a v1
device never writes a unit that has a field it doesn't know"); (b) the drafting
API copies the unknown fields of the writes it kills into the new write, which
is a merge rule and contradicts "nothing picks a winner" when the unit is
contested. Leaning to (a), which then also makes (2) close to pointless; see
the alternatives.

### 3. Schemas only grow

Never remove or rename a unit, field, family or type; never change an
encoding; never move a field; never make a unit write-once later. Deprecate
instead: keep it declared, stop writing it. Offer
`RecordSchema.isSuccessorOf(RecordSchema previous)` (and the same for a family
set) so each app can pin a snapshot of its schemas in a test and fail CI on a
change that isn't growth. This rule holds whatever is decided about 1 and 2.

## Alternatives considered

- **A. Fetch again after an upgrade.** Keep the door as it is. On an upgrade
  that adds families or units, the app's transport fetches again from the shelf
  from the beginning (or from a per-family cursor). Nothing is held locally, so
  there's no local junk exposure. It costs a full download per upgrade and
  depends on the shelf keeping every write forever, which the B2 design may or
  may not promise. It doesn't fix "reads throw after a removal", but rule 3
  forbids removal.
- **B. Rule 3 only, plus "new fields go in new units".** If schemas only grow
  and a field is never added to an existing unit, then a v1 device meets v2
  writes only as unknown units or unknown families. Holding those (1) is still
  needed for mixed versions; carrying (2) isn't.
- **C. Version the schema in the wire.** Each write carries its schema version;
  a device refuses writes from newer versions and asks the user to upgrade.
  This turns silent divergence into a loud block, at the cost of stopping
  mixed-version use.

## Open risks

- **Held junk is a local storage exposure.** Today the door caps what can be
  stored: only writes the app understands. Holding every wire-valid write means
  anyone who can reach the transport can fill a device with writes to made-up
  families. B2 prices floods per publisher at the shelf, not on the device.
  Candidates: a held-bytes cap per publisher; holding only from publishers the
  device already knows; holding only writes that cite a family in a
  shelf-published family list. Unresolved.
- **Removal becomes "nobody reads it", never "gone".** Storage only grows.
- **The automatic `recompute` trigger** needs the store to persist the family
  set it last saw, which adds to the `JournalStore` contract that codraw and
  engram are implementing right now.
- **Held writes and `unsent()`.** A held write was absorbed, so it is never
  sent. That's right today, but if the app wants a device to relay for older
  peers, held writes must be relayable without being understood.
- This changes what the door admits, so by codraw's rule it gets a cage-match
  once it's code.

## Questions for the strike

1. Is holding (1) the right frame, or does alternative A or C dissolve it?
2. Is carrying (2) worth having, given the whole-unit kill flaw?
3. What else does rule 3 have to forbid to be complete?
4. How should held junk be capped, and does any cap reopen the silent-divergence
   hole it was meant to close?
