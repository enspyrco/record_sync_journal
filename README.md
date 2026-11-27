# record_sync_journal

Records kept on the device as a journal of whole field-group writes. Each write
names the writes its author saw, and a field group's value is every write nobody
has replaced: no clock, and nothing picks a winner.

This is step 1a of codraw's B2 design (`docs/crucible/canvas-sync-order-authority/DESIGN.md`
in [enspyrco/codraw](https://github.com/enspyrco/codraw)), built generic over the
record type so codraw and engram share one implementation.

## The model

- **A record** has an *identity* (`{family, …fields}`), from which the app's
  `IdentityFamily` derives a key and type. The record's id is that family plus
  its key, so two families never share an id, and the id never travels.
- **A unit** is a group of a record's fields, always written whole. Every record
  also has `_tomb`, holding `_deleted`.
- **A unit write** is one canonical JSON object, as bytes. Its id is the
  SHA-256 of those bytes. It carries `kills`, the unit's live writes its author
  saw and replaces, and 128 bits of salt, so naming a write is evidence of
  having held it.
- **A unit's value** over its writes `S`: `live = S ∖ ⋃ kills`, and `shown` is
  the set of distinct live values. More than one is a race (`contested`), and
  every value is shown. Any write that names them settles it.
- **A delete** also carries `saw`, the content writes it witnessed. A deleted
  record is hidden only when the live deletes together saw every live content
  write; otherwise it is a ghost listing what they didn't see.

## The parts

| Part | What it does |
|---|---|
| `canonicalJson` | One text per value: sorted keys, integers with `|n| ≤ 2^53 − 1`, strings, booleans, null, lists, maps. No doubles. |
| `Door.admit(bytes)` | Hash, strict UTF-8, JSON, canonical re-encode test, exact schema. Same verdict on the VM, dart2js and dart2wasm (C11). |
| `UnitWriteDraft` | The four writes an author can ask for: `content`, `delete`, `restore`, `deterministicBirth`. |
| `UnitState`, `RecordView` | The set function, and `DrawnRecord` / `HiddenRecord` / `GhostRecord`. Pure functions of a set of writes. |
| `RecordJournal` | `write`, `absorb`, `relay`, `read`, `readAll`, `recompute`, `unsent`, `markAcked`. |
| `JournalStore` | The storage seam, and the only lock. `InMemoryJournalStore` ships here; apps write their own over sembast, drift, … When tabs or isolates share a store, its `transaction` takes the lock that spans them, outside the database transaction: `transaction(fn) => withLock(() => db.transaction(fn))`. |
| `isolateLocalQueue` | A one-at-a-time queue, for a store whose transactions don't already exclude each other. |
| `HashedIdentityFamily` | The common family: key = UUIDv8 of SHA-256 over the identity's canonical text. |

## Writing

```dart
final journal = RecordJournal(store: InMemoryJournalStore(), families: [noteFamily]);

// Capture what the person saw when the gesture began, not at append.
final seen = switch (await journal.read(id)) {
  null => <WriteId>{},                        // nothing stored: a birth
  Readable(:final view) => view.units[body]?.liveIds ?? {},
  UnreadRecord() || UnreadableRecord() => null, // this build can't edit it
};
if (seen == null) return;
await journal.write([
  UnitWriteDraft.content(
      identity: note, unit: body, fields: {'text': 'hi'}, observedLive: seen),
]);

// Transport is the caller's: send unsent() bytes, absorb() what arrives.
for (final e in await journal.unsent()) send(e.bytes);
await journal.absorb(received);

// Importing an archive whose publisher may be gone: relay() takes the write
// like absorb() and lists it in unsent(), so it reaches the other devices.
await journal.relay(archived);
```

`unsent()` lists writes whose `Provenance` is `authored` or `relayed`. A store
keeps each entry's provenance by name.

## Two app versions over one store

A newer build may add families, and units to an existing record type, but must
never change a shipped unit: its field set, a field's encoding, its write-once
bit, or a family's name, identity fields, key or `resolve`. Never rename or
reuse a name; deprecate it instead.

The package keeps one more rule for its own wire: every future version stays a
canonical JSON object within today's `maxNestingDepth`, with an integer `v`.
The door checks those before it can read `v`, so a wire that broke them would
be refused as malformed by every older build, not left out as newer. Bumping
`v` can't fix that, so the depth limit can never rise. Any other change to the
wire (salt, ids, keys) bumps `v`.

Under that rule, a write an older build can't read is refused as
`unknownFamily`, `unknownUnit` or `unknownVersion` (`Refusal.isNewerSchema`),
and reads leave it out and say so:

- `read` returns `Readable(view)`, with the left-out writes in `view.unread`;
  `UnreadRecord` when every stored write was left out, which is not absence, so
  don't create the record again; or null when nothing is stored.
- An `UnreadWrite` keeps its id to itself, so no `kills` or `saw` can name a
  write this build never read.
- Any other refusal of a stored write, or a write stored under the wrong record,
  means the rule was broken or the store is corrupt: `read` and `readAll`
  return that record as `UnreadableRecord`, with its `fault`. Nothing throws,
  so a corrupt record can't crash a shipped build, and it can't hide the rest.
- `recompute` stays strict and throws on any refusal, so an older tab can never
  rebuild a newer tab's writes away.
- An older build's `absorb` refuses a newer frame and stores nothing. After an
  upgrade, the app's transport reads every write again from the start, so
  what it refused while it was older arrives now
  (`docs/design/schema-evolution/DESIGN.md` §3).

## Reading is not free: cache views above the journal

A view is worked out from its record's write bytes on every `read`: each write is
hashed, decoded and checked again, and on a shared store the read also takes the
cross-tab lock. That is fine for a gesture, not for a frame. An app that renders
often keeps its own views, rebuilt when it writes and when `absorb` returns `Appended`
(not `AlreadyHeld`, which a retrying peer sends often), and reads the journal
only then.

## Testing on every compiler

```sh
dart test
dart test -p chrome
dart test -p chrome -c dart2wasm
```
