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
| `RecordJournal` | `write`, `absorb`, `read`, `readAll`, `recompute`, `unsent`, `markAcked`. |
| `JournalStore` | The storage seam, and the only lock. `InMemoryJournalStore` ships here; apps write their own over sembast, drift, … When tabs or isolates share a store, its `transaction` takes the lock that spans them, outside the database transaction: `transaction(fn) => withLock(() => db.transaction(fn))`. |
| `isolateLocalQueue` | A one-at-a-time queue, for a store whose transactions don't already exclude each other. |
| `HashedIdentityFamily` | The common family: key = UUIDv8 of SHA-256 over the identity's canonical text. |

## Writing

```dart
final journal = RecordJournal(store: InMemoryJournalStore(), families: [noteFamily]);

// Capture what the person saw when the gesture began, not at append.
final seen = (await journal.read(id))?.units[body]?.liveIds ?? {};
await journal.write([
  UnitWriteDraft.content(
      identity: note, unit: body, fields: {'text': 'hi'}, observedLive: seen),
]);

// Transport is the caller's: send unsent() bytes, absorb() what arrives.
for (final e in await journal.unsent()) send(e.bytes);
await journal.absorb(received);
```

## Reading is not free: cache views above the journal

A view is worked out from its record's write bytes on every `read`: each write is
hashed, decoded and checked again, and on a shared store the read also takes the
cross-tab lock. That is fine for a gesture, not for a frame. An app that renders
often keeps its own views, rebuilt when it writes and when `absorb` admits
something new, and reads the journal only then.

## Testing on every compiler

```sh
dart test
dart test -p chrome
dart test -p chrome -c dart2wasm
```
