# TEMPER.md — schema evolution (two-layer door)

**Overall verdict:** RECAST (4 of 4)
**Struck:** dt-1795496325, families seated: Maxwell + Noether, Carnot, Tesla (Wu disabled). Every cited file was sent.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | Holding is right; carrying breaks what `kills` means; the junk risk is mispriced. |
| Carnot (GPT) | RECAST | Separate durable receipt from interpretation; freeze units; one shared projection can't serve two schema versions. |
| Noether (DeepSeek) | RECAST | Held writes aren't deduplicated, indexed or relayable; drop carrying; complete rule 3. |
| Tesla (Grok) | RECAST | Don't take unprojectable bytes onto the device at all; the shelf keeps them, an upgrade reads again; freeze units. |

## Fatal flaws (deduped, most severe first)

1. **Carrying unknown fields (§2) lets an old editor destroy new data.** Raised by all four. A v1 edit kills a v2 write whose field it never saw. DISPOSITION: delete §2. Existing units' field sets are frozen, and new data goes in new units or families.
2. **Holding breaks deduplication.** `_append` deduplicates with `txn.holds`, which reads the projection only. A held write is never projected, so each redelivery appends it again. Raised by Carnot, Noether and Tesla (Maxwell missed it). DISPOSITION: dissolved with holding (see 4).
3. **Old and new tabs share one store and one projection.** A stale codraw tab and a new tab would rebuild the projection against different doors, and the fingerprint trigger makes them oscillate. Raised by Carnot and Tesla. DISPOSITION: no automatic trigger and no fingerprint. A reader skips stored writes its door refuses instead of throwing. `recompute` stays strict: a refusal aborts the transaction and nothing lands, so an older tab can't strip a newer one's writes.
4. **Holding is a second copy of what the shelf already keeps.** Raised by Tesla as the frame; Carnot and Noether said A dissolves holding *iff* the shelf retains and the cursor can be replayed; Maxwell said "unverified". CHECKED against codraw's B2 DESIGN (branch `docs/canvas-sync-order-authority`): §3.1 "GET serves the paged per-publisher index and entries by id", §2.4/C7 "the shelf holds bytes and decides nothing semantic", §2.5 a reader "reads every publisher's log anyway", and nothing evicts entries; volume is bounded by per-publisher sub-quotas (§3.5). DISPOSITION: no local holding. After an upgrade, the transport reads the shelf again from the start. This also repairs writes that doors already deployed have dropped, which local holding can never do (Tesla, Carnot). Engram's transport is unchecked: named open.
5. **Rule 3 is incomplete.** Raised by all four. It also has to freeze a unit's field set, field codecs, write-once bits, `IdentityFamily.resolve` and key derivation, a family's identity fields, and `allowsDeterministicBirth`, and it must forbid reusing a deprecated name. `isSuccessorOf` can only see names; it can't see closures or codecs. DISPOSITION: fold the freeze list into §3, give `isSuccessorOf` the checks it can make, ask the app to supply resolve vectors and codec fixtures for the snapshot test, and state plainly what the check cannot see.
6. **Held junk and the cap.** Raised by all four, in different shapes. DISPOSITION: dissolved with holding. No unprojectable bytes come onto the device. Volume is the shelf's sub-quota, which already exists. (Maxwell's correction stands for the bytes that are admitted: the door caps shape, not count, and per-publisher volume belongs to the transport.)
7. **Reads throw (`_readmit`), and one bad write takes down `readAll`.** Raised by Noether and Tesla. DISPOSITION: a read skips a write its door refuses. It throws on nothing.

## What holds

- The id is the bytes; stored bytes are never rewritten.
- The wire parse before the schema parse, with depth counted on the bytes first.
- A view as a pure function of one record's projected set, within one schema generation.
- Deprecation as "still declared, no longer written".
- Alternative C loses: it would block ordinary mixed-version use.

## Disposition

RECAST → fold into DESIGN.md (round 2) and strike again.

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** Holding is the right frame, but carrying unknown fields (§2) is an illegal move against the package's own law, and the "held junk" open risk is mispriced: the door today caps shape, not volume.

**Producer first:** The design guards three harms.
(a) *Silent permanent divergence.* Trigger: a v2 write reaches a v1 device (external, can't be prevented). Producer: ours. `absorb` drops a write it can't understand, and nothing re-delivers it. §1 deletes that producer (store wire-valid writes and project them later) instead of adding a check, so it is the right shape.
(b) *Reads throw.* Producer: ours. `_readmit` puts stored bytes through the *current* door and throws on a refusal. §1 removes it too: a refusal at read time means "held", not a crash.
(c) *Local storage flood.* The proposal answers it with a new check, a held-bytes cap. The producer named is "hold anything wire-valid", but the same producer exists today: `HashedIdentityFamily` takes any string fields, so a flooder can already fill a device with valid writes to made-up records in a *known* family. Holding adds no volume exposure that isn't already there. The cap check therefore guards the wrong producer. Volume is a per-publisher concern at the transport or shelf for every write, held or not. Don't add a cap here.
(d) Rule 3's `isSuccessorOf` is a check. Its producer is a developer editing a schema declaration. A type can't fully stop that (source can always be deleted), but it can be shaped so removing something is an edit nobody makes by accident: see fold-back. The CI snapshot stays, because the producer lives outside the type system.

**Fatal flaws:**
- **ILLEGAL MOVE (§2, unstated assumption): carrying breaks what `kills` means.** README: "naming a write is evidence of having held it." A v1 device that edits a unit kills a v2 write whose field it never saw. Its kill claims it replaced a value it could not show its user, so v1 silently picks a winner, against the package's first rule ("nothing picks a winner"). The design names this as the "whole-unit kill flaw" and leans on a workaround, but it is a broken invariant, not a tradeoff. The fix is to *not carry*: a write with an undeclared field is **held** on v1 like any other write v1 doesn't understand. v1's later edit doesn't name it, so after v1 upgrades the unit shows as **contested**, with both values shown. That is the model working: the race comes out into the open instead of being lost. Holding keeps the invariant, so §2 dissolves into §1, and "new fields go in new units" becomes advice rather than a rule.
- **PREMISE FALSE (Open risks, first bullet): "today the door caps what can be stored".** It caps shape, not count. See Producer first (c). The risk that is left over is real but not new: no device-side volume bound for anything. That belongs to the transport/shelf contract, and holding writes is not what opens it.
- **INCOMPLETE (§3): rule 3 misses changes that orphan records or refuse old writes.** It also has to forbid:
  - changing a family's identity field set, or `HashedIdentityFamily`'s key derivation (this changes every key, so it is a rename);
  - turning `allowsDeterministicBirth` from true to false (old unsalted births are then refused);
  - tightening `IdentityFamily.resolve` so it rejects identities it used to accept;
  - reusing a deprecated field or unit name with a different meaning.
  The wire `v` stays at 1: a new `v` is a new door, and needs its own design.
- **COUPLING TO REMOVE (Open risks, third bullet): the automatic recompute trigger.** It adds a stored family fingerprint to a `JournalStore` contract that two apps are implementing this week. Remove it: keep a held index in the log (seq → write id, written when a write is held), and re-try only the held entries each time the journal opens. The cost is proportional to the number of held writes, there's no new stored state to keep right, and no app has to remember to call `recompute`. A full `recompute()` stays as the repair tool.
- **WRONG FRAME, partially (Alternatives, A): re-fetching isn't an alternative to holding but the backstop for it.** Holding makes up for no-relay on *this* device. A device that was offline, or installed fresh, still needs the shelf. A depends on whether B2's shelf keeps every write. I can't check that from this bundle, and it should be stated as an open fact, not assumed in either direction.

**What holds:**
- §1's split: deciding admission to the log by wire validity and admission to the projection by schema validity removes the producer of both silent divergence and throwing reads, instead of guarding them.
- Indexing held writes by write id alone is forced by `RecordId` needing the family, and that's fine: projection is where record ids are needed, and held writes aren't projected.
- §3 holds regardless of §1 and §2, and `isSuccessorOf` plus an app snapshot test is the right mechanism for a producer that lives in app source.
- Alternative C (refuse newer versions loudly) correctly loses: it trades silent divergence for blocking ordinary mixed-version use, which the design says lasts days to weeks.

**If RECAST, what to fold back:**
- Delete §2. Replace it with: "A write with an undeclared field, unit or family is held. Races between held and projected writes come out as contested after an upgrade, by the existing set function." Add a test: v2 writes field f into unit u, v1 edits u, v1 upgrades, then u is contested and shows both.
- Rewrite the first Open risks bullet: volume bounds are a transport/shelf concern for all writes. Holding writes adds no new class of exposure. Drop the held-bytes cap.
- Extend §3 with the four extra prohibitions above.
- Replace the fingerprint trigger with a held index that is re-tried when the journal opens.
- State as an open question whether B2's shelf keeps every write, and treat re-fetching as the backstop for offline and fresh devices, not an alternative to holding.


## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** Keep the wire log and schema projection split. Drop unknown-field carrying, freeze existing units, and make durable receipt, replay, and concurrent schema versions explicit contracts. Alternative A works only with guaranteed replay; C still needs a delivery contract. Neither currently dissolves holding. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, the entropy comes from coupling durable receipt to interpretation.

**Producer first:** The harm is permanent disagreement between devices after an upgrade. The trigger is receiving a newer-schema write; our producer is the admission/storage path discarding its bytes while transport advances beyond them. Remove that coupling: acknowledge receipt only after durable retention or a durable replay obligation. The second harm is erasing newer fields: our whole-unit drafting step produces a replacement without those fields and kills their source. Freeze each published unit's field set to remove that producer. Reads throwing are produced by _readmit treating current-schema rejection as storage corruption; schema-specific projection removes that failure path. Resource exhaustion is produced by unconditional durable append of arbitrary wire-valid input; bounded receipt with explicit backpressure must replace that policy. Wire validation itself remains necessary because untrusted bytes still cross the boundary.

**Fatal flaws:**
- Make permanent loss on schema mismatch impossible: separate durable receipt from schema interpretation and transport progress; then schema checks become unnecessary as permission to retain a write. The proposal moves toward this but never specifies the receipt contract. A Held result, storage failure, or exhausted budget must have defined cursor and acknowledgement consequences. Otherwise the same producer survives behind a new result type.
- One shared projection cannot represent several active schemas. Codraw has many tabs: an old tab can rebuild away a new tab's units, and a new tab can promote writes the old tab cannot interpret. A persisted 'last family set' makes this oscillate; transaction isolation only serializes the oscillation. Scope projections by an explicit interpretation revision, or compute schema-specific views from the shared immutable log. Define how stale clients operate throughout an upgrade.
- Carrying unknown fields preserves bytes while allowing an old editor to destroy their meaning. Copying fields introduces unresolved merge semantics when killed writes disagree. Delete this machinery: make existing unit field sets immutable and put additions in fresh units. Rule 3 currently permits precisely the field addition that makes proposal 2 destructive.
- A held-bytes cap without a recovery protocol reinstates silent divergence. Evicting retained writes or dropping new ones after advancing transport progress defeats the guarantee. Per-publisher limits also require trusted publisher attribution, which JournalEntry does not retain. Define which layer owns that provenance and budget. Local append policy must be bounded, and capacity exhaustion must produce explicit backpressure or a durable replay obligation.
- The automatic rebuild trigger cannot be derived reliably from family names or structural schema growth. IdentityFamily.resolve is application code: the same names can acquire different key derivation, accepted identities, or type selection. Encoding, defaults, and deterministic-birth behavior can change outside RecordSchema. isSuccessorOf cannot prove these semantics. Require an explicit interpretation revision and a compatibility contract that freezes existing identity mappings and value meanings.
- Holding changes the authoritative membership set, but the store contract still deduplicates through projection membership. A held write has no projected entry, so repeated delivery can append it repeatedly. Demotion creates the same problem. Log membership must be indexed by write id independently of every projection; append and membership update must be atomic.
- The rollout cannot recover writes already dropped by deployed clients. Upgrading their door only preserves future deliveries. State the initial recovery requirement: replay available shelf history, obtain missing writes through another durable source, or explicitly report that historical completeness cannot be established. Recompute cannot reconstruct absent bytes.

**What holds:**
- Immutable, content-addressed bytes belong in the durable evidence layer; interpretation belongs in a rebuildable projection.
- Unknown families need no fabricated RecordId. Write-id indexing is sufficient for retention and deduplication.
- Rejecting malformed wire input remains justified. Schema ignorance and malformed input require different outcomes.
- Append-only schema naming is useful, provided existing units, identity mappings, encodings, and semantics remain stable.
- Alternative A can replace local holding when replay retention and cursor recovery are guaranteed. Alternative C can block unsupported editing, but a schema-version field alone cannot recover discarded writes.

**If RECAST, what to fold back:**
- Adopt alternative B with stronger rules: new units or families for new data; immutable existing unit field sets; stable identity resolution, encodings, omission meanings, deterministic-birth recipes, and write-once behavior.
- Specify a receipt state machine before extending JournalStore: retained, duplicate, invalid wire, and capacity blocked. Connect each outcome to transport acknowledgement and replay behavior.
- Use one immutable log with global write-id membership and schema-specific projections. Make revision selection and rebuild publication atomic for concurrent tabs.
- Keep local authoring schema-strict. Holding is a remote receipt outcome, not permission for a local draft to succeed without entering its author's view.
- Specify partial-view behavior, especially deletion: an older client cannot witness held content in saw. Explain the resulting delete, conflict, and later-promotion behavior instead of promising complete views.
- Dijkstra: "Simplicity is prerequisite for reliability." Remove field carrying and automatic inference of semantic compatibility; those mechanisms spend work without establishing the promised invariant.


<!-- Noether and Tesla both landed between two checks; their order between them was not observed. -->

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design breaks the invariant that every write admitted to the log is either projected under a known schema or is a bounded, indexed, relayable held write; it creates unindexed duplicates, unbounded local storage, and leaves the network-level divergence hole open.

**Producer first:** The design adds/hardens three guards. (a) The wire/schema split that holds wire-valid-but-schema-invalid writes. It catches the harm of a v2 write being dropped by v1 and silently diverging. The producer is `Door.admit` returning `Refused` for unknown family/unit/fields, plus `RecordJournal.absorb` returning `NotAdmitted`, plus `unsent()` filtering `authoredHere`. That producer can be removed—store every wire-valid write and project only schema-valid ones—but the design must also index and relay the held set; it does neither. (b) `isSuccessorOf` for growth-only schemas. It catches the harm of a non-growth schema change making old writes refused or silently misresolved. The producer is the app’s `IdentityFamily.resolve` and `RecordSchema` construction. That producer can be made structurally unable: persist the last family/schema digest and refuse to open the journal on a non-successor, and extend the schema to cover encodings/resolve versions. (c) The implied held-write existence/dedup check. It catches duplicate held writes and storage exhaustion. The producer is `RecordJournal.absorb` appending every wire-valid frame with no held index or per-publisher cap. It can be made unable by a held index and an authenticated per-publisher cap. The design leaves (a)’s relay, (b)’s runtime enforcement, and (c)’s cap unresolved.

**Fatal flaws:**
- Held writes are not deduplicated. DESIGN §1 says held writes are in the log, not the projection, indexed by write id only. But `JournalTransaction.holds` is defined as “Whether the projection holds [write]” (`journal_store.dart`), and `_append` uses it to dedupe (`record_journal.dart`). A held write is not in the projection, so `holds` is false; re-absorbing the same held write appends a duplicate log entry and returns `Appended` instead of `AlreadyHeld`. CLASS: missing state / broken invariant.
- The held set has no store contract. The design says held writes are “indexed by write id only,” but `JournalStore` exposes no held index, no `isHeld`, no `heldAfter`, no way to enumerate held writes for recompute or relay. `absorb` cannot distinguish a new held write from a duplicate held write without scanning the log. CLASS: missing interface / contract gap.
- Carrying unknown fields in a known unit (DESIGN §2) creates a silent data-loss path. v1 admits a v2 write to a unit v1 knows, with a field v1 does not. v1 treats it as live. When v1 later edits that unit, its new write has no v2 field and kills the v2 write, so the v2 field is lost for every device. The design admits this as a known flaw and leans to (a) “new fields go in new units,” which makes (2) pointless. CLASS: wrong option-frame / unsafe default.
- Rule 3 is incomplete. It forbids removal/rename/move/encoding change/write-once-later, but it does not forbid changing `IdentityFamily.resolve` behavior. A family can keep its name and type while changing how it derives keys or schemas, orphaning old data exactly like a rename. `RecordSchema.isSuccessorOf` cannot see this. It also cannot see encoding changes because `RecordSchema` carries only unit/field names, not field types or encodings. CLASS: unstated assumption / incomplete invariant.
- “Read never throws” is not structural. A projected write that the current door refuses will still be in the projection until `recompute` runs. `read` and `readAll` call `_readmit`, which throws `StateError` on refusal (`record_journal.dart`). The design says a refused stored write is “not projected; it is held,” but that requires recompute to have already demoted it. The automatic recompute trigger is an open risk and depends on persisting the last family set, which adds to the `JournalStore` contract. CLASS: missing failure mode / temporal coupling.
- Held writes are not relayable, so the network-level silent-divergence hole is not closed. The design’s open risk admits: “A held write was absorbed, so it is never sent.” If v1 is the only device that received a v2 write and v3 later syncs through v1, v1 will not relay it because `unsent()` returns only `authoredHere` (`record_journal.dart`). Holding fixes v1’s local view but not v3’s. CLASS: under-counted blast-radius / broken convergence invariant.
- Held junk is unbounded. The design says anyone who can reach the transport can fill a device with writes to made-up families; B2 prices floods at the shelf, not the device (Open risks). `absorb` appends every wire-valid frame. There is no cap, no authentication, no backpressure. CLASS: missing failure mode / security.
- The automatic `recompute` trigger adds to the `JournalStore` contract that codraw and engram are implementing right now (Open risks). This is an unnecessary coupling. The app upgrade is the natural point to call `recompute`; the journal can also make reads non-throwing by filtering refused projected writes on the fly. CLASS: coupling that should be removed rather than guarded.
- The `Held` result conflicts with existing `AlreadyHeld` semantics. `AlreadyHeld` currently means “admitted, and already held [projected]” (`record_journal.dart`). The design adds `Held` for “wire-valid, schema-invalid, newly stored in log.” Without a held index, the API cannot tell a duplicate held write from a new held write. CLASS: naming/state confusion / broken API.

**What holds:**
- The core split between wire validity and schema validity is sound: the wire rules (hash, canonical JSON, depth, UTF-8, wire keys, id-list ordering, salt shape) are a pure function of bytes and can decide log admission without schema.
- Rule 3’s growth-only discipline is the right invariant for schema evolution; deprecation instead of removal is correct.
- Holding wire-valid but schema-invalid writes in the log is the right way to avoid silent drop on the absorbing device, provided the held set is bounded, indexed, and relayable.
- The observation that `recompute` can promote held writes after an upgrade is correct, if the held set is properly tracked.
- The known flaw in (2) is correctly identified; the design should trust its own analysis and drop carrying.

**If RECAST, what to fold back:**
- Add a first-class held-write index to `JournalStore`: `isHeld(WriteId)`, `heldEntriesAfter(seq)`, per-publisher held bytes, and a way to enumerate held writes for `recompute` and relay. `_append` must check both projection and held index before appending.
- Drop §2 (carrying unknown fields). Require new fields to go in new units. Hold writes with unknown fields instead of projecting them. This preserves the whole-unit kill invariant without the known data-loss path.
- Complete rule 3: forbid changing `IdentityFamily.resolve` behavior and field encodings. Extend `RecordSchema` (or a companion schema snapshot) to include field types/encodings and a family-resolution version. Persist a schema/family digest in the store; at journal open, refuse a non-successor family set. The CI check is a convenience, not the only guard.
- Make read non-throwing structurally: `read`/`readAll` should use a non-throwing admit and skip refused writes, not call `_readmit` that throws. `recompute` should be an explicit migration step, not an automatic trigger that expands `JournalStore`.
- Resolve relay: either make held writes relayable as opaque bytes (with a per-publisher cap and no schema interpretation) or explicitly require the transport to re-fetch after upgrade. Do not leave this as an open risk. If the shelf can promise retention, alternative A dissolves §1 entirely; if it cannot, the held set must be relayable.
- Cap held junk: require authenticated publisher identity and enforce a per-publisher held-bytes cap with backpressure. If the cap is exceeded, stop absorbing from that publisher and surface an error; do not silently drop legitimate writes. This bounds the DoS without reopening the normal mixed-version hole.
- Update `Absorption` API: rename current `AlreadyHeld` to `AlreadyProjected` or similar; add `Held` (newly stored, not projected) and `AlreadyHeld` (already in log as held). Make the return value distinguish these states.

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The upgrade unions two kill-relations that were each computed against a different projected set, so the night the schema "grows" every co-written unit forks, while retransmission rings the log at the sync frequency because idempotency still lives in the projection. Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** The permanent split (a record's two devices, or two tabs, disagree forever, and the disagreement surfaces as a contest only after upgrade) is produced by this package, not by the peer. The trigger is a frame whose unit, family, or field the running schema does not declare. The producer is `absorb` treating that refusal as finished business, plus a later writer emitting a whole-unit kill computed from the smaller projected set. Make that outcome impossible: a refusal does not advance the shelf cursor, the shelf keeps the opaque bytes, and an upgrade reads them again; a unit's field set is frozen at birth so an older writer never authors a kill of a newer field. Then the held-byte cap, the known-publisher gate, the shelf family-list, and `isSuccessorOf` as a net that blesses "growth" become unnecessary. A second producer, filling the device, is ours as well: durability of every wire-valid frame. Delete it. Do not append a remote frame this schema will not project. Bytes a newer tab already appended to a shared log stay there; the older reader skips them on read. Untrusted bytes still cross the transport boundary, so the wire parse (object, depth, strict UTF-8, canonical, key set, salt shape, sorted ids) stays; that check is the input itself arriving. What no schema object in this package can make impossible is an app codec or `IdentityFamily.resolve` changing meaning behind an unchanged name. `isSuccessorOf` on `RecordSchema` cannot see those closures. Say so in the rule. Do not add a second comparator.

**Fatal flaws:**
- Make permanent divergence impossible: refusal does not ack, the shelf retains opaque bytes, upgrade re-fetches, and existing units are frozen; then held-caps, publisher allow-lists, family lists, and a subset-shaped `isSuccessorOf` become unnecessary (DESIGN.md §1–§3, Alternatives A/B, Open risks, Questions 1 and 4).
- Purity does not commute with union. Each side's `kills` were calculated from the writes that side projected. Weeks of mixed versions, with both sides writing the same unit, are the normal codraw case. Promotion replays the log into one set and the view, a pure function of that set, finds a contest neither device had. Upgrade night is the incident. Section 2's carry makes the other failure: the old writer kills the new field outright, on every device, because a unit is written whole (DESIGN.md §2 known flaw, and the kill casualty in "The problem").
- The idempotency bit is `JournalTransaction.holds`, and `holds` looks only at the projection (`journal_store.dart`). A held write is defined to be in the log and absent from the projection (`DESIGN.md` §1). The same frame delivered again, which sync already does, appends again. The log swells at retry frequency. `AlreadyHeld` cannot be said. Ack watermarks count phantom seqs. `recompute` walks duplicates. There is no store operation "this write id is in the log."
- Automatic `recompute` is keyed on the set of family names, and it `clearProjection`s (`DESIGN.md` §1, Open risks). Adding a unit or a field does not change that set, so the common growth never promotes. On codraw's shared multi-tab store the equality oscillates: the old tab and the new tab each see the other's recorded set, each rebuilds the whole log, sembast re-runs the body, and the older door strips the newer units out of the projection. The 3am sound is that oscillator.
- Rule 3's "only grow" is the mutation that shatters the crystal. A successor defined as superset passes "add a field to a unit," which is the whole-unit kill, and passes nothing about encodings, `resolve` moving a key, `allowsDeterministicBirth` flipping, or a write-once bit lifting. The silent-wrong row in the table is exactly the producer this check cannot see. Write-once lifted on one side and held on the other (write-once is schema validity, so the kill is held) waits in the log until the flags match, which rule 3 never requires (`DESIGN.md` §3, `values_schema_excerpt.dart`, `Refusal.writeOnce`).
- Section 2 dissolves itself. Carrying unknown fields leaves them visible to the race and lost on the next old write. Copying them forward is a merge that picks a winner. Alternative B already says the carry is idle once fields are born only inside new units. Shipping §2 beside that lean is two designs in one door (`DESIGN.md` §2, Alternative B).
- `v == 1` is classed as wire validity, so a future wire is dropped, not kept (`DESIGN.md` §1, `Door.admit`). The escape hatch is on the side of the door that forgets. The generation about to pin `761228f` is already that forgetting door. Local `Held` begins only on the build after that pin. It cannot regrow bytes this cohort already refused. The only repair that reaches those bytes is the shelf. If B2 does not retain opaque frames forever, neither A nor `Held` closes the hole, and the design is blocked on that promise rather than on a second log.
- One wire-valid frame is unbounded in width. Depth ≤ 64 does not bound bytes. Held junk is a single canonical object of made-up families, repeated by the duplicate-append above. Any cap that then deletes the bytes puts the original producer back on the throne, under disk pressure, which is the moment an upgrade most needs the quarantined frame (Open risks, Question 4).

**What holds:**
- The id is the bytes. Rewriting stored bytes to migrate them is amnesia. That axiom survives.
- Wire parse before schema parse survives, including depth counted on the bytes before the decoder recurses. Untrusted frames still hit that boundary.
- A view as a pure function of one record's projected set survives inside a single schema generation. The break is union across generations.
- "A read throws `StateError`" is the wrong blast shape. `readAll` runs `_readmit` across every record, so one foreign unit takes down the whole journal. Skipping on read is the right local tolerance.
- Deprecation by still declaring a frozen unit, and simply no longer writing it, survives. Tomb stays a witness, not a kill.
- Option (b), copying unknown fields into the next write, is correctly distrusted.
- No clock. One transaction for append. Salts drawn before the transaction. Those stay.

**If RECAST, what to fold back:**
- Replace §1's `Held` result, the projection split, the family-set trigger, and the cap candidates with two sentences. A remote frame this door will not project is `NotAdmitted`, and `NotAdmitted` does not advance a shelf cursor. Upgrade reads the shelf again from the start, or from a per-family cursor, which is Alternative A, and it is mandatory because the pinned door has already dropped this generation's skew. Shared-store readers skip log bytes they will not project and do not `clearProjection`. `recompute` runs only forward, once, at a monotonic schema generation an older tab is not allowed to roll back. `JournalStore` gains no family-set field and no held index, so the stores landing with `761228f` stay the contract.
- Delete §2. The monotone is Alternative B, sharpened. New families, new types, new units. A unit's field names, their codecs, its write-once bit, and that family's `resolve` and `allowsDeterministicBirth` are frozen in the revision that introduces them. Spell the freeze as the list `isSuccessorOf` actually has vectors for, including resolve vectors and codec fixtures supplied by the app. Where the meaning lives in a closure the package cannot see, say the check does not cover it.
- Answer the four questions in the doc in those words, so the next strike cannot rehydrate `Held`: A dissolves local holding if and only if the shelf retains opaque bytes; carrying is withdrawn; rule 3 forbids the freeze list above, and "add a field to an existing unit" is the forbidden growth; no cap, because the bytes were never taken onto the device.


---

# Round 2 — struck dt-1795496898

**Overall verdict:** RECAST (4 of 4). Families seated: Maxwell + Noether, Carnot, Tesla. The bundle was 76 KB, including round 1's TEMPER.md, and Carnot still seated.

**What changed between rounds.** Round 1 struck the core (holding, carrying). Round 2 left the core standing: no holding, frozen units, replay from the shelf, and strict `recompute` all hold in all four strikes. Every round-2 flaw is about the recovery contract around the core, or about timing.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell | RECAST | Skip-on-read is wider than its producer; replay has no completion record; every live envelope must reach the shelf. |
| Carnot | RECAST | Replay must be a durable pending operation; a new type in an existing family refuses as `invalidIdentity`, which `isNewerSchema` misses. |
| Noether | RECAST | Replay crash safety; retention as a hard precondition; a shared `ackedSeq` loses tab B's writes (FALSE, see below). |
| Tesla | RECAST | Already-shipped tabs have no skip, so they throw; `read` fakes absence; `unread` ids could be forged into a `saw`; freeze the door and the set function too. |

## Fatal flaws, deduped, with dispositions

1. **Replay has no completion record** (all 4). DISPOSITION, fold: replay is a durable pending operation. It is marked done for version N only after every publisher's log has been absorbed to its head. An interrupted replay resumes or starts over, since absorbing is idempotent.
2. **Retention and publication are assumed** (all 4). DISPOSITION, fold as a ship gate: this design is blocked until codraw's B2 states both that the shelf never deletes a publisher's entries (a full sub-quota refuses the POST and leaves history), and that every envelope sent live is also posted. That is codraw's design, so it goes to codraw's session, with Nick's yes.
3. **Tabs that shipped before skip-on-read throw on new units** (Tesla). True: `761228f`'s `read` throws. DISPOSITION, fold as a timing rule, not Tesla's store-per-generation: skip-on-read ships in the package *before* either app releases to users. Then every generation that can share a store already skips. Store-per-generation would also work, but it means refilling a store per upgrade and would leave old tabs stale indefinitely. Neither app has shipped `761228f` to users, so the cheap route is still open. It closes the moment one does.
4. **`read` fakes absence** (Tesla; checked against `lib/src/record_journal.dart:84-86`). DISPOSITION, fold: `read` returns a sealed result: a view, `UnreadRecord`, or none, the last only when nothing is stored.
5. **Skipped ids could be forged into a `saw` or `kills`** (Tesla). DISPOSITION, fold: `unread` holds a distinct type, which `UnitWriteDraft` doesn't accept.
6. **Skip-on-read is wider than its producer** (Maxwell). DISPOSITION, fold: skip only `isNewerSchema` refusals, and throw on the rest, as today. A refusal of any other kind means the freeze was broken or the store is corrupt.
7. **A new type in an existing family refuses as `invalidIdentity`** (Carnot). DISPOSITION, fold into the freeze: a new record type comes with a new family. A family's `resolve` is then frozen whole, and `isNewerSchema` stays exact.
8. **The freeze has to cover the package too** (Tesla). DISPOSITION, fold: every byte string a shipped v=1 door admitted stays admissible, and the meanings of `kills`, `saw`, ghost and contest stay fixed. A tighter door, or a different set function, needs a new wire `v`.
9. **Writes during a replay act on a prefix of history** (Tesla). DISPOSITION, REJECTED with reason: that is the normal state of any offline device. Writes made against part of history surface as contests or ghosts when the rest arrives, which is the model working. Refusing writes until caught up would make an offline device read-only.
10. **A blindness bit that blocks deletes** (Tesla). DISPOSITION, REJECTED: an old device's incomplete `saw` becomes a ghost, which round 2 already named as honest. Blocking deletes adds state to stop an outcome the model already displays truthfully.
11. **A shared `ackedSeq` drops another tab's writes** (Noether). DISPOSITION, FALSE: `unsent()` returns every write authored on this device, whichever tab wrote it (`lib/src/record_journal.dart:110-112`). A tab's transport sends the other tabs' writes too.
12. **Engram's transport** (Noether, Carnot). DISPOSITION, precondition: until engram's session confirms it has a replayable log, this design doesn't cover engram's mixed versions.
13. **Every device replays at once on release morning** (Tesla). DISPOSITION, fold as advice: add jitter to the start of the replay.
14. **Update-prompt spam** (Maxwell). DISPOSITION, fold: count distinct families and units, not frames.

## Disposition

RECAST → fold into DESIGN.md (round 3). Round 3 is the last in the budget. Items 2 and 12 need other repos' sessions.


## Round 2 strikes, verbatim (order landed: Noether, Carnot, Tesla in one check; Maxwell composed in-process)

## MaxwellMergeSlam's Design Strike (round 2)

**Verdict:** RECAST

**Summary:** Deleting holding is right and the freeze is the load-bearing rule. But skip-on-read as written skips *every* refusal, which turns a freeze violation from a loud crash into data quietly vanishing. The replay has two unstated preconditions: it records that it finished, and every frame reaches the shelf.

**Producer first:**
(a) *Harm: a reader crashes on stored bytes.* The producer is ours: `_readmit` puts stored bytes through the current door and throws. Under the freeze, a stored write can be refused for exactly two reasons. Either a newer build wrote it into a shared store (expected; the refusal is `unknownFamily`, `unknownUnit` or `unknownVersion`), or the freeze was broken or the store is corrupt (a bug). §2 skips both. The second case should never be produced at all, and skipping it hides the evidence. Make the skip exactly as wide as the expected case: skip only `isNewerSchema` refusals and keep `StateError` for the rest. That's not a new check, it's narrowing an existing one to its producer.
(b) *Harm: permanent divergence.* Trigger: a newer frame reaches an older device (external). Producer: ours, the device's dropping being final. §3 makes it not final, because the bytes stay on the shelf and an upgrade reads them again. It's the right shape, a deletion of finality rather than a check.
(c) *Harm: an old editor kills unseen data.* Producer: a unit whose field set differs between versions. The freeze (§1) removes that producer for the cases it can see. `SchemaSnapshot` is a check on a producer that lives in app source, and it can't be made a type, so the check stays. The design says that, which is correct.

**Fatal flaws:**
- **Skip-on-read is wider than its producer (§2).** A stored write refused with `fields`, `writeOnce`, `invalidIdentity` or `salt` means the freeze was broken or the store is corrupt. Skipping it, and listing it in `unread` alongside the legitimate newer-build writes, makes a bug look like a stale tab. Fold: skip only `isNewerSchema` refusals; throw on anything else, as today; `unread` holds only newer-schema ids.
- **The replay has no completion record (§3).** "On the first start of a new app version" says when it begins, not when it counts as done. A crash or a closed tab halfway through, if marked done at start, loses the rest for good: the same silent divergence, moved. Fold: the app records "replayed for version N" only after the last page is absorbed; an interrupted replay starts over (absorbing is idempotent). Several codraw tabs may replay at once; that costs extra bandwidth, not correctness.
- **Unstated assumption: every frame reaches the shelf (§3, Context).** The replay only repairs what the shelf holds. B2 §3.2's live channel carries envelopes "in the same bytes through the same door". If any envelope travels only live and is never posted, an older device that refused it live can't get it back. B2 §2.3 says an envelope is "sealed once, persisted, then sent", which I read as posted to the shelf, but the excerpt doesn't say the live channel never carries anything the shelf lacks. Fold: state it as a B2 requirement next to the retention line: "every envelope sent live is also posted to the shelf."
- **Minor: newer-schema refusals as an "update" prompt can be spammed.** Any vouched publisher can send `unknownFamily` frames and make every device ask the user to update. It's quota-bounded and only an annoyance, but the prompt should count distinct families, not frames.

**What holds:**
- Deleting holding dissolves round 1's dedup, multi-tab oscillation and cap flaws at once, because they all came from a second copy of the shelf.
- Freezing unit field sets keeps `kills` meaning "I saw this" across versions. Under the freeze, a device's blind spot is always a whole unit it can't write, so it never turns into a kill.
- Strict `recompute` on a shared store: an old tab fails loudly instead of rebuilding a newer tab's writes away.
- The mixed-version ghost is correctly named as the model being honest, not as a bug.
- `JournalStore` gains nothing, so the contract both apps are implementing stays put.

**If RECAST, what to fold back:**
- §2: skip only `isNewerSchema` refusals, throw on the rest, and `unread` lists only newer-schema writes.
- §3: the replay is marked done for version N only after its last page; interrupted replays start again.
- Tradeoffs: add "every live envelope is also posted to the shelf" as a B2 requirement beside retention.
- §3: the update prompt counts distinct unknown families or units, not frames.


## CarnotCodeCarver's Design Strike (round 2)

**Verdict:** RECAST

**Summary:** Round 2 deletes substantial wasted work: holding, carrying and automatic rebuilds stay deleted. The remaining gap is the recovery contract. A replayable shelf is a sound replacement for local holding only when publication, retention and crash-safe replay are guaranteed. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, the entropy moved into transport rather than disappearing.

**Producer first:** The harm is permanently missing supported data after an upgrade. The trigger is schema skew, interrupted replay or concurrent transport activity; our producer is discarding a refused frame while allowing transport progress to become durable without a durable recovery obligation. Make recovery an unfinished operation until a complete replay commits its progress; then successful application startup need not grant permission to forget recovery. Another harm is erasing data an editor never displayed. The producer was whole-unit replacement across changing field sets; freezing published units removes that producer for compatible releases. Strict recompute prevents destructive projection publication, and transaction rollback is an appropriate structural boundary. Untrusted bytes must still be parsed, so wire validation cannot be deleted. Semantic compatibility also cannot be proved from arbitrary app closures; the snapshot and fixtures must remain explicitly limited evidence.

**Fatal flaws:**
- Make interrupted recovery impossible to mistake for completed recovery: model replay as a durable pending operation, completed only after its required history has been consumed successfully; then the 'first start of a new app version' trigger becomes unnecessary as the recovery authority. Currently a crash, quota failure or network interruption after that first start has no specified retry or completion semantics. The shelf can retain every byte while this device never requests the missing bytes again.
- Shelf capability is being promoted into a delivery guarantee. GET-by-id, publisher indexes and absence of an eviction rule establish neither that every relevant write reaches the shelf nor that it remains discoverable forever. B2 explicitly permits POST refusal for quota, and its live channel also delivers envelopes. Specify when a live-delivered write becomes durably recoverable, what happens when publication fails, and what retention and publisher discovery promise replay relies on. The named retention dependency is candid, but it remains an unresolved prerequisite for the central guarantee.
- Shared-tab safety covers projection transactions but leaves transport progress unscoped. If an old tab can advance a shared publisher cursor past a frame after the newer tab finishes its upgrade replay, the newer tab can miss a write it understands with no subsequent upgrade to trigger recovery. Define cursor ownership by consumer interpretation, or give the current consumer an independent complete scan. This is conditional on cursor sharing, which the design must settle rather than leave implicit.
- The newer-schema cue misses a permitted evolution path. Adding a record type within an existing family can require resolve to accept identities it previously rejected. The old door returns invalidIdentity, not unknownFamily or unknownUnit, so isNewerSchema remains false. On a shared store, these are also skipped writes that are not an unknown unit or family, contradicting §2's classification. The current refusal vocabulary cannot reliably distinguish an unsupported new type from an invalid identity.

**What holds:**
- Frozen unit field sets, codecs, omission meanings and write-once behavior remove the legitimate mixed-version whole-unit erasure path. This remains a contract for compatible authors, not proof that arbitrary kills represent observation.
- Filtering stored bytes through each reader's door allows different schemas to share an additive projection. Strict transactional recompute preserves that projection when an older door refuses any logged write.
- The deletion ghost is an honest consequence of incomplete observation. An old view can show deletion while a newer view shows a ghost; the UI must accept this explicitly.
- Immutable bytes and replay preserve write ids and kill relations. Completed replay can run again safely because admitted writes remain projected and deduplicated.
- Deleting local holding and field carrying is the simpler architecture when the transport satisfies the recovery contract. No held index, cap or inferred schema fingerprint needs to return.
- The freeze list substantially covers the declared compatibility surface, and the design correctly admits that snapshots cannot prove arbitrary codec or resolver semantics.

**If RECAST, what to fold back:**
- Replace 'first start' with a transport recovery lifecycle: durable pending state, resumable or restartable scanning, completion boundaries for publisher discovery and pages, and retry after crash, storage exhaustion or failed absorption. Partial replay must remain visibly incomplete.
- Make durable publication and retention requirements explicit prerequisites. Obtain the corresponding B2 commitment and define the live-before-publication case. Apply the same contract to engram before claiming coverage there.
- Specify cursor ownership across simultaneous app versions. An older consumer's refusal must never discharge a newer consumer's delivery obligation.
- Describe unread as 'not interpretable by this build'. Treat isNewerSchema as a heuristic, or introduce an explicit unsupported-type distinction where the identity protocol can establish it; do not label arbitrary invalid identities as newer.
- Verify the design with recovery traces: crash mid-replay and restart without another upgrade; old-tab cursor advancement after new-tab replay; quota-refused publication; and a new record type in an existing family.
- Dijkstra: "Simplicity is prerequisite for reliability." Keep the deleted machinery deleted; finish the transport contract that makes its deletion valid.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant at stake is conservation of delivery: every write authored here must eventually be sent, and every write on the shelf must eventually be absorbed by every device that can admit it; the design breaks this under multi-tab transport and partial replay.

**Producer first:** The freeze check (`SchemaSnapshot.isFrozenBy`) guards the harm of an old device killing a newer device’s write to an unseen field. Producer: a developer editing a schema declaration. The producer cannot be fully removed—source can always be deleted—but the check makes accidental violation structurally hard, so it stays. The read-skip check guards the harm of an old tab throwing on a shared store when a newer tab projects an unknown unit. Producer: the old tab’s read path calling `_readmit` that throws. This producer can be removed: make `read`/`readAll` use a non-throwing admit and skip refused writes. The design does this. The strict `recompute` guards the harm of an old tab clearing the projection and rebuilding it without newer writes, silently dropping them. Producer: `recompute` skipping refused writes instead of throwing. This producer can be removed: make `recompute` abort the transaction on refusal. The design does this. The transport replay guards the harm of a write dropped by an earlier deployed build never being seen again. Producer: the earlier build’s `absorb` returning `NotAdmitted` and advancing its cursor. That producer is already deployed and cannot be removed; re-reading the shelf is the only repair. But the replay’s own failure mode—crash mid-replay—is produced by the transport not persisting a completion marker. That producer can be removed: persist a durable per-publisher cursor and mark the new app version complete only after all replays finish.

**Fatal flaws:**
- **Missing failure mode: transport replay has no crash-safety protocol.** §3 says “On the first start of a new app version, the transport reads every publisher’s log from the beginning and absorbs each frame.” It does not say when the new version is marked as started, nor how a crash mid-replay resumes. If the version marker is written before replay completes, a crash leaves the device missing writes forever; no future upgrade re-reads because the version is already marked. CLASS: missing failure mode / partial replay.
- **Broken invariant: multi-tab shared store with a global `ackedSeq`.** The context says codraw’s store is shared by many tabs. `unsent()` returns entries after the global `ackedSeq` that are `authoredHere` (`record_journal.dart`). If tab A authors a write at seq 2 and tab B authors at seq 1, and tab A’s transport marks acked 2, tab B’s write at seq 1 falls below the watermark and `unsent()` never returns it. It is never sent. The design says `JournalStore` gains nothing, so the global ackedSeq stays. Producer: the shared ackedSeq. Make it unable: one transport per store, or per-tab ackedSeq, or make `unsent()` filter by author identity. CLASS: broken invariant / under-counted blast-radius.
- **Unstated dependency: shelf retention is assumed, not promised.** The entire repair path assumes the shelf never deletes a publisher’s entries. B2 does not promise this; the design names it as an open risk. If B2 evicts, writes dropped by earlier builds are lost forever, and the design’s central claim—“It also repairs what earlier builds dropped”—is false. Producer: B2’s eviction policy, which this design does not own. Make it unable: get B2 to promise retention in writing, or accept that earlier drops are unrecoverable and remove the claim. CLASS: unstated assumption / dependency not owned.
- **Engram transport unchecked.** The design says if engram has no replayable store, the design does not cover engram’s mixed versions. That is a precondition, not a design. It must be folded in as a hard requirement or engram must refuse mixed-version sync. CLASS: incomplete scope / missing precondition.

**What holds:**
- Freezing unit field sets closes the kill-of-unseen-data hole: an old device never writes a unit it does not know, and never writes a field it cannot see, so its `kills` cannot name a write it never witnessed.
- Skip-on-read plus strict `recompute` is safe on a shared multi-tab store: an old tab can read (skipping) and write (without killing unknown units), but cannot rebuild the projection and strip newer writes; it fails loudly instead.
- Deleting holding and carrying removes the second copy of shelf bytes, the dedup hole, and the junk cap.
- The wire parse before schema parse remains.

**If RECAST, what to fold back:**
- Add a transport replay protocol to §3: persist a per-publisher cursor and an “upgrade in progress” flag. Absorb frames, advancing the cursor only after each frame commits. Mark the new app version complete only after all publishers’ replays finish. On crash, resume from the cursor. If quota blocks, surface backpressure and do not mark complete.
- Add a multi-tab transport rule: either one transport per store, or make `ackedSeq` per author, or change `unsent()` to take an author id. State it in the design because `JournalStore` is shared.
- Make shelf retention a hard precondition: B2 must guarantee “the shelf never deletes a publisher’s entries.” Until then, state that earlier drops are unrecoverable.
- For engram, add a precondition: engram must have a replayable store, or it must refuse mixed-version sync (alternative C for engram only).
- Add tests for delete ghost and unread records.

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The upgrade frequency is the shatter frequency: one new unit projected into the shared store meets a sleeping tab that still runs today's throwing `_readmit`, and the journal rings itself to glass at the hour the schema was supposed to grow. Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** Four guards, four producers, all ours.

- *An old writer kills a field it never saw.* Trigger: a newer build ships new data. Producer: a whole-unit write computed from a smaller field set. The freeze rule deletes that producer for fields. `SchemaSnapshot.isFrozenBy` only samples what the app puts in the snapshot; it cannot see a codec closure or a `Door.admit` that tightens. Keep the rule. Do not add a second comparator. Do extend the freeze to the v=1 admit predicate and to `RecordView`'s set function, which are the same producer in package code.
- *A stored write crashes `readAll`.* Trigger: a byte in the projection this door refuses. Producer: `_readmit` throwing, and the new tab's `project` placing that byte where an older binary's `_readmit` must walk it. Skip-on-read deletes the producer only inside the binary that contains the skip. The sleeping tab does not contain it. Delete the producer by giving each door generation its own store file, so the old walk never observes the new byte. The skip stays as the residual for a corrupt byte inside one generation. It is not the mixed-tab fix.
- *An old tab strips a newer projection via `recompute`.* Producer: `clearProjection` then project-what-this-door-admits. The strict throw deletes that producer only while the store rolls the transaction back and the app does not retry. A retry loop is the same producer wearing a clock. Make `recompute` a non-retryable stale-door result that writes nothing, and keep it off the open path.
- *A newer-schema frame is forgotten and the user authors against a finished-looking record.* Trigger: a frame this door refuses. Producer: `absorb` returning `NotAdmitted`, the per-publisher cursor advancing, the refusal living only in a counter the design says is not stored, and `read` building a complete view from whoever remains. `Refusal.isNewerSchema` names the frame and leaves that producer at work. Delete the producer: a durable per-publisher blindness bit (not the bytes) that stays set until shelf replay is caught up, and a delete/restore path that will not author while the bit is set. Separately, `RecordView.unread` hands back `WriteId`s. The producer of a forged witness is a later `saw` that copies them. Make those ids a type `UnitWriteDraft.delete` cannot accept.

Shelf eviction is not our producer to delete. It becomes one the moment B2 compacts. That is a blocking precondition, not a check to add here. Untrusted wire bytes still cross the boundary, so the wire parse stays: it is the input arriving.

**Fatal flaws:**
- **The skip ships in the wrong generation (DESIGN.md §2, §4, Context).** Today's `read` / `readAll` run every projected byte through `_readmit` and throw `StateError`. Round 2's skip is not built, and a tab left open keeps the binary it loaded. The first new unit that the new tab `project`s into the shared sembast file makes `read` of that record, and `readAll` of the journal, throw on every tab that has not reloaded. There is no upper bound on that wait. §4 forbids a generation key on `JournalStore`, and that ban is right; the file the store opens is the coupling. One projection shared across door generations is the resonant frequency of the whole recast.
- **Replay is a long subset, and authoring during it unions two kill-relations again (DESIGN.md §3, question 3).** Full-shelf absorb is many transactions, not one commit. A crash, a version flag set at the start, or an older tab advancing the same per-publisher cursor (the design says a cursor *may* advance past a refusal) leaves a prefix. Writes authored against that prefix kill and witness a proper subset; when the tail arrives, the view forks on upgrade night, which is the incident round 1 already heard. Release morning every client phase-locks on page zero of every publisher. That herd is the same frequency, played on the shelf.
- **False completeness, then a forged witness (DESIGN.md §2, §3, question 1).** The freeze does close the field-kill: an old door cannot author a unit it does not declare, and `kills` stay per unit. A delete is different. `saw` can only name writes this process stored. A remote frame that was `NotAdmitted` is not in `unread`, because `unread` is a filter over stored bytes, and §3 says the refusal is never stored. The old device draws a finished delete. The ghost appears later, only on a device that holds both writes. Meanwhile §2 publishes the skipped ids as ordinary write ids, so a delete that copies `unread` into `saw` claims the README's witness for bytes the door refused. That is the unseen-data kill, re-entered through the courtesy channel.
- **`read` forges absence (DESIGN.md §2).** `readAll` grows `UnreadRecord` when every write was skipped. `read` is unspecified, and the code returns null when the filtered set is empty. A point read is how an editor decides to birth. Null says the record is not there, and a birth or a content write lands on top of a life the door refused to show.
- **The freeze stops at the app's name list (DESIGN.md §1, question 4).** `isFrozenBy` cannot see a later `Door.admit` that refuses bytes a shipped v=1 door admitted (tighter fields, identity parsing, salt, subset-versus-equal). Those bytes are already in logs. The new door then skips them on read and throws inside `recompute`, which is history going dark on a patch release. The same silence exists if `RecordView`'s kill, `saw`, ghost, or contest rule changes: the bytes stay, the winner changes. Neither is on the freeze list. Codec fixtures and resolve vectors remain samples; that limit is already stated and can stay stated.
- **Retention is still a hum, not a latch (DESIGN.md Cost; B2 excerpt §3.1, §3.5).** Nothing in the excerpt evicts, and a full sub-quota refuses a POST rather than dropping history. The excerpt also never says the shelf keeps a publisher's entries for the life of the canvas. This design's only repair reads that shelf. A later compaction, the night the quota policy "gets smarter", deletes the bytes no device stored. The one-line precondition is named and left optional, so the producer stays armed.

**What holds:**
- The id is the bytes. Rewriting them to migrate is amnesia. That axiom is the crystal.
- Deleting `Held`, carrying, the held index, the fingerprint trigger, and the junk cap. A second local copy of shelf bytes was the slag; it stays deleted. `JournalStore` gaining no held index is the right contract for the stores on `761228f`.
- Freezing a unit's field set, so two versions disagree only about whole units, families, and types. Under that rule a same-unit kill still means "I saw this and replace it."
- When both the unseen unit write and the old delete are in one projection, a ghost is the model telling the truth. A second delete by a door that can name the unit is the honest completion. The alternative, a delete that ignores units its author cannot see, hides data.
- Wire parse before schema parse, depth counted on the bytes first. That check is the untrusted frame itself.
- A view as a pure function of one record's projected set, inside one door generation. The break is union across generations and across a replay prefix.
- Deprecation as "still declared, no longer written," and never reusing the name. The wire `v` staying 1.
- Engram staying a named non-goal until its own log is replayable. Alternative C still loses for codraw: it blocks ordinary mixed-version drawing.
- Strict `recompute` as "build aside, swap, or throw so nothing lands," once a single generation owns the file.

**If RECAST, what to fold back:**
- In DESIGN.md §2 and §4, replace "tabs share one store and skip" with a store-per-door-generation rule. The app opens the store file named by the schema snapshot id. `JournalStore`'s interface gains nothing. A tab running an older binary keeps opening the old file, stays stale, and cannot throw on bytes it will never be shown. The new file is filled from the shelf, not by copying the old projection. The old file is left in place while any tab can still have it open. Skip-on-read and `RecordView.unread` remain for a byte this generation's own door refuses. They are not the mixed-tab mechanism.
- In §3, make replay a gate with one watermark. Per publisher, the cursor resets to the start of the log; that cursor is the only "upgraded" bit; a crash resumes it; replay is single-flight per store; a tab of another generation does not advance it. `write` is refused with a typed not-caught-up result until every publisher cursor sits on the shelf head. Authoring against a prefix is how the upgrade-night fork is minted. Jitter the herd so release morning is not one chord on page zero. A later per-family cursor may narrow a *completed* replay. It must not replace the watermark.
- In §2, make `read` return `UnreadRecord` whenever every stored write for that id was skipped, including the point read. Give skipped ids a type that `UnitWriteDraft.delete` and `kills` cannot accept. Add a durable per-publisher blindness bit, owned by the transport, set when `isNewerSchema` fires, cleared only when replay of that publisher is caught up. Delete and restore refuse while it is set. State the residual in one sentence: a binary already shipped can still author an incomplete `saw`; after the missing unit is replayed that delete is a ghost, and the new code must not "finish" it by copying unseen ids.
- In §1, add two freeze lines: bytes a shipped v=1 door admitted stay admissible for the life of `v = 1` (a tighter door is a new wire version), and `RecordView`'s meaning of `kills`, `saw`, ghost, and contest is frozen the same way. Keep the sentence that codecs and `resolve` outside the supplied vectors are invisible to `isFrozenBy`.
- In Cost, change the retention bullet from a named hope to a ship gate: this design is blocked until B2 states that a shelf never deletes a publisher's entries, and that a full sub-quota refuses the POST and leaves history. Until that sentence exists, replay has nothing to read back.



---

# Round 3 — struck dt-1795497502 (last round in the budget)

**Overall verdict:** RECAST (4 of 4). **The design is UN-TEMPERED (provisional): the 3-round budget is spent without a clean strike.** Families seated: Maxwell + Noether, Carnot, Tesla.

**What the trend says.** Round 1 struck the core. Round 2 struck the recovery contract. Round 3 struck the edges of the recovery contract (which cursor a replay reads, which lock it takes, when it counts as done) and the order of one check in the door. Each flaw below that two or more families raised came with a specific fix that the families agreed on, and every one has been folded into DESIGN.md. The folded version has not been struck.

## Fatal flaws, deduped, with dispositions

1. **The door reads `v` after the v=1 key set** (Carnot, Tesla; checked: `lib/src/unit_write.dart:350` before 358). A future wire version with a new key refuses as `schema`, and a stale tab throws. FOLDED: read `v` before the v=1 grammar; every future wire keeps an integer `v`.
2. **The replay resumes from a cursor that went past refused frames** (Tesla, Maxwell). FOLDED: the replay has its own per-publisher cursors starting at zero, and resumes only from offsets it saved itself. The ordinary sync cursor is keyed by schema snapshot id.
3. **The replay lock is the store's non-reentrant transaction lock** (Carnot). That deadlocks on codraw's `navigator.locks`. It is the same class of mistake that round 3 of the PR 3 cage-match deleted, written back in at design level. FOLDED: a separate replay lock.
4. **"Done" is measured against a publisher list sampled at the start** (Tesla, Noether). FOLDED: list, read every log to an empty page, list again.
5. **Publication isn't ordered before the live send** (Tesla, Noether). FOLDED into precondition 1: the POST is acknowledged before the live send, and a refused POST leaves the entry unacknowledged.
6. **One corrupt record takes down `readAll`** (Maxwell). FOLDED: `UnreadableRecord`.
7. **The package's own freeze has no mechanism** (Tesla, Noether). FOLDED: a package corpus of admitted bytes and set-function fixtures.
8. **A full-view capability, so drafts can't act on a view that looks whole** (Tesla). REJECTED: a device behind on sync is in exactly this state, and a gate would make it read-only (round 2, item 9).
9. **Record the generation in the store; delete `recompute`** (Noether). REJECTED: the first is the round-1 fingerprint again, and the second is the repair tool working as intended.

## Disposition

UN-TEMPERED (provisional). See DESIGN.md's status line. Next is Nick's call: run a fourth strike on the folded version, or accept it and let the cage-match on the code be the next fire.

## Round 3 strikes, verbatim

## MaxwellMergeSlam's Design Strike (round 3)

**Verdict:** RECAST

**Summary:** The core is sound and the replay lifecycle is finally a contract. One path remains on which a device that can read a write never holds it: after the replay, an older tab moves a page cursor that belongs to the newer generation.

**Producer first:** The bad outcomes and their producers, as of round 3:
(a) *A readable write is never held.* Trigger: a frame arrives at a build that can't read it (external). Producer: some record that says "this publisher's log has been read up to page P" being moved forward by a reader that refused frames in pages before P. §3 removes it for the replay (pending flag, single-flight). But it doesn't say whose cursor the *ongoing* reads after the replay advance. On a shared codraw store, the old tab and the new tab can share one. Make it structurally impossible: key the page cursor by the build's schema snapshot id. A generation's cursor is then moved only by readers that refuse nothing a sibling of that generation could read, and an old tab's progress never counts for a newer build. That's a key, not a check.
(b) *A kill or saw names an unseen write.* The producer was a unit whose field set differs between versions; the freeze deletes it. Copying a left-out id was the other producer; `UnreadWrite` being a separate type deletes it.
(c) *A crash during a read.* The skip-or-throw split leaves the throw only for refusals that mean the freeze was broken or the store is corrupt. That's a check on a producer outside the package (an app breaking the freeze), and it can't be deleted. Its blast radius can be narrowed, though: see the last flaw.

**Fatal flaws:**
- **A cursor shared across generations (§3, Question 1).** After the replay, the transport keeps reading pages as they grow. If tabs on two builds share one per-publisher cursor, an old tab advances it past a newer-unit frame it refused. The new tab never reads that page from the shelf, and holds the frame only if it also happened to get it live. That is the round-1 divergence again, smaller. Fold: page cursors are keyed by the schema snapshot id. An older generation keeps its own, and a newer one starts from its replay.
- **One corrupt stored write takes down all of `readAll` (§2).** The throw is right for `read` of that record. For `readAll` it turns one bad record into an outage for the whole journal. Fold: `readAll` returns that record as a third kind, `UnreadableRecord(id, refusal)`. It still never fakes absence, and the app still sees something is wrong.

**What holds:**
- The freeze, including the package's own v=1 door and set function, and "a new type comes with a new family". Under it, two builds disagree only about whole families and units, and `isNewerSchema` is exact.
- Skip-or-throw: skipping only newer-schema refusals makes a stale tab quiet and a broken freeze loud.
- The sealed `read` result and `UnreadWrite`: a write the reader can't see can't be mistaken for absence, or copied into a witness.
- Replay as a durable pending operation, cleared only at every publisher's head, resumable, single-flight and jittered.
- Rejecting the write gate during replay: a prefix of history is what offline is, and the model already shows the overlap.
- The ship gates are named as gates, not as hopes.

**If RECAST, what to fold back:**
- §3: page cursors are keyed by the schema snapshot id. An old generation's progress never moves a newer one's cursor.
- §2: `readAll` reports a record whose stored write throws as `UnreadableRecord(id, refusal)`, not by throwing for the whole journal. `read` of that record still throws.


## CarnotCodeCarver's Design Strike (round 3)

**Verdict:** RECAST

**Summary:** The core holds: frozen units and guaranteed shelf replay dissolve local holding. Two boundaries still need precise contracts: version dispatch and replay locking. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, the remaining entropy is in orchestration.

**Producer first:** The first harm is an older tab crashing when reading a newer tab's stored write. The trigger is a new wire version; our producer is applying v1 grammar checks before identifying that version, then treating the resulting schema refusal as corruption. Remove that ordering dependency. Untrusted bytes still require validation, but an unsupported version need not pass v1's grammar. The second harm is replay hanging indefinitely. The trigger is replay absorbing its first frame; our producer is holding the store's non-reentrant transaction lock while absorb attempts to acquire it again. Remove the coupling between replay ownership and transaction exclusion. The snapshot test addresses incompatible edits to application code; that producer cannot be eliminated by package types because codecs and resolve closures remain application supplied. Its explicitly limited coverage is honest.

**Fatal flaws:**
- Make newer wire versions unable to crash older readers: establish a permanently readable version discriminator before version-specific validation; then v1 shape checks become unnecessary for unsupported versions. In the supplied door, exact top-level keys are checked before v. A future v2 write with an additional key therefore returns schema rather than unknownVersion, and §2 throws on the stored write. Merely splitting out the v != 1 refusal does not establish the claimed classification. The new-wire design must inherit this dispatch contract.
- Replay ownership and transaction locking cannot use the same non-reentrant lock as described. Holding that lock across replay makes absorb deadlock when it opens a transaction; releasing it between transactions permits two replays to interleave and does not establish single-flight. The store contract explicitly permits non-reentrant locks. Separate the replay coordinator's ownership from the lock used by individual journal transactions.

**What holds:**
- With the retention and publication gates actually satisfied, shelf replay replaces local holding and repairs previously dropped writes.
- Frozen unit contents remove the unknown-field carrying problem. New types requiring new families closes the invalidIdentity classification hole.
- Readable, UnreadRecord and null distinguish partial knowledge from absence. Typed unread values reduce accidental witness fabrication.
- Strict, transactional recompute prevents an older tab from publishing a projection that strips newer writes.
- Writing during replay honestly produces contests or ghosts; it does not require another permission gate.

**If RECAST, what to fold back:**
- Specify version dispatch ordering and the stable discriminator contract. Include the scenario: a newer tab stores a supported future-version write with a different shape; an older reader returns unread rather than throwing.
- Give replay a separate app-owned coordinator. Each absorb takes only its ordinary store transaction lock. Define ownership recovery after a crashed tab and ensure completion belongs to the pending version whose replay actually ran.
- Keep the shelf guarantees and Engram exclusion as hard ship gates. Do not reintroduce held bytes, automatic recompute, or schema fingerprints.
- Dijkstra: "Simplicity is prerequisite for reliability." Preserve the machinery already deleted; fix these two boundaries without rebuilding it.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The conserved quantity is the set of admitted writes — the design conserves it by *deletion* on the device and restores it by an *external* replay the package never runs, so the invariant "a device that can read a write holds it" is conserved only outside this design, with no signal inside the store that it is ever missing.

**Producer first:**
The design adds/hardens these checks, and here is the harm and the producer each guards:

- **Skip-on-read + the `isNewerSchema` split (§2).** Harm: a stale tab throws on a newer unit a newer tab projected into a *shared* store. Trigger: the newer tab writes. Producer: ours — the shared projection holds a write the current door refuses, and `_readmit` throws. Removable? The producer is the shared store across schema generations; the design accepts the stale tab ("sees less, and is told so"), so skip-on-read is the right shape. Keep, narrowed to `isNewerSchema` only.
- **`replayPending(version)` (§3).** Harm: a crash mid-replay leaves the device permanently short. Producer: the transport advancing past a dropped write and then crashing. Removed by "replay from the start." Keep.
- **`UnreadWrite` distinct type (§2).** Harm: a left-out id forged into `kills`/`saw`. Producer: an editor copying an unread id into `observedLive`. Removed by the type. Keep.
- **`SchemaSnapshot.isFrozenBy` (§1).** Harm: a developer mutates a frozen declaration. Producer: a schema edit. Not fully removable (closures). Keep, with the stated blind spots.
- **Preconditions 1–3.** Harm: the shelf doesn't retain / engram has no replayable log. Producer: other repos. Keep as gates.

**One producer is ours and is not removed.** The package drops every write it can't read and keeps **no record that it dropped one**. The device log is a strict subset of the shelf, and the only thing that closes the gap is the transport's replay — which §3's own first line says the package cannot run. That producer is the source of every liveness failure below. It should be made structurally unable (the store must know it is short), not handed to a transport contract with no observable in the store.

**Fatal flaws:**
- **Liveness is not conserved by the package (§3, first line; Q1).** "A device that can read a write comes to hold it" holds only if the transport replays, every time, forever, with a publisher list and a shelf snapshot that are complete at the instant it reads. Precondition 1 pins "posted," not "posted *before the live send*" nor "posted *before the replay reads the log*"; and §3 fixes the publisher set "as listed when the replay began," so a POST that lands after the read, or a publisher that joins mid-replay, is not in the replay and, with no further version change, is never re-read. A device then holds a strict subset forever, silently. CLASS: under-counted blast-radius / missing failure mode / unstated ordering assumption. **Make it impossible:** the store records the schema generation it was last replayed to, and a read that could be missing a write this build can now read says so; or the package refuses to serve reads until the transport confirms the replay to the store. Then the transport's honesty stops being the only guard.
- **`read` and `recompute` contradict each other on the same shared projection (§2).** §2 makes `read` *skip* a newer-schema refusal and `recompute` *throw* on any refusal — same bytes, two behaviors, on the one store both tabs share. The design resolves the contradiction with "Nothing calls it automatically," which makes `recompute` dead in a single-tab store (`_append` appends and projects in one transaction, so the projection always equals the log) and a guaranteed throw in a shared store. A dead tool that throws exactly where the app would naturally call it ("repair after update") is a coupling to remove, not a guard. CLASS: coupling that should be removed rather than guarded / dead check. **Make it impossible:** delete `recompute`, or narrow it to "rebuild only for the generation that wrote the log," and let an old tab's rebuild be *unrepresentable* rather than *throwing*.
- **The freeze — the design's central conserved quantity — is enforced by discipline, not structure (§1, last line).** `isFrozenBy` cannot see codecs or `resolve` on identities outside the vectors; those are precisely the producers of "two versions disagree about what an existing unit holds": a codec change silently misreads every stored write, and a `resolve` change orphans every key. The design names the blind spot and delegates to app-supplied fixtures. That is honest, but it means the premise of the entire design is not conserved by anything shipped here. CLASS: check narrower than its producer / unstated assumption. **State it as the invariant it is:** the app *must* ship codec fixtures and resolve vectors, the snapshot is a convenience and not the guard, and the store carries a schema digest so a non-successor generation cannot open it.

**What holds:**
- The wire/schema split — admit by wire validity, project by schema validity — is the right cut, and it removes the producer of both silent divergence and throwing reads.
- The freeze list is complete for what the door can see: unit field sets, field encodings, write-once bits, a family's name/identity fields/key derivation/`resolve`/`allowsDeterministicBirth`, a record type's name, and deprecation-not-removal.
- The id is the bytes; stored bytes are never rewritten; no clock; salts drawn before the transaction.
- Skip `isNewerSchema`, throw otherwise — correct under the freeze. `unknownVersion` split out of `schema` is right.
- **Q2 holds:** `kills` is within a frozen unit (every write to it is readable, so it can only name what the author saw), and `saw` is a subset witness (it cannot name an unseen write). Missing a newer unit's write is the named ghost, not a forged witness.
- **Q3 holds:** under the freeze, a newer build's write can only cause `unknownFamily`/`unknownUnit`/`unknownVersion`, because a new record type comes with a new family and a family's `resolve` is frozen whole. `invalidIdentity` is then a freeze break and should throw.
- The three preconditions as gates, and `replayPending` as a durable, crash-resumed flag.

**If RECAST, what to fold back:**
- Record the last-replayed schema generation in the store, and give `read`/`readAll` a way to say "this projection may be missing writes this build can now read." Do not leave the liveness invariant to a transport the package cannot observe. Add a test: replay reads the shelf, a POST lands after, a second read still reports the gap.
- Delete `recompute`, or restate it as "rebuild only for the generation that wrote the log." Add a test that an old tab on a shared store cannot rebuild a newer tab's write away — by construction, not by a thrown transaction.
- Pin the ordering as a precondition: a peer's POST lands **before** the live send, and the shelf's per-publisher index is read-your-writes for the replay. Otherwise the replay can complete over an incomplete log.
- State plainly that the freeze is enforced by the app's codec fixtures and resolve vectors, and carry a schema digest in the store so a non-successor generation is refused at open, not merely failed in CI.

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The upgrade's "done" note rings at a cursor that already stepped over the very frames this schema can finally sound, so the night the app learns the new unit is the night it stops listening for it. Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** The snapshot test guards a shipped schema edit orphaning or rewriting old writes. Its producer is the app author. Names, units, and field sets can be made unchangeable by the freeze list the snapshot actually hashes. Codecs and `resolve` outside the supplied vectors live in closures the package cannot see, so that residue cannot be deleted from here; the README's confession stays, and a second runtime comparator must not be added. The wire parse stays too: untrusted bytes still cross the transport boundary, and that check is the input itself arriving. Skip-on-`isNewerSchema` guards a single newer unit taking down `read` and `readAll`. Its producer is `_readmit` throwing on a stored refusal. Skipping `unknownFamily`, `unknownUnit`, and `unknownVersion` removes that producer. Throwing on every other stored refusal stays: those bytes are already inside the store, and a corrupt frame or a broken freeze is the harm itself. `UnreadWrite` guards a `kills` or `saw` that names a write the author never saw. Its producer is `UnitWriteDraft`, which still accepts any `WriteId`. A wrapper the draft merely declines does not make that producer unable, as long as the id can be lifted out. `replayPending` guards an upgrade counted done while a write this build can now read is still absent. Its producer is the transport retiring the flag, or resuming, on a walk that `NotAdmitted` already stepped past. The flag is the right object, and the completion rule in §3 leaves that producer alive. The two B2 sentences guard a replay that faithfully rebuilds a shelf that never held the live frame. Their producer is `markAcked` moving on live delivery while POST is still in flight, refused by sub-quota, or lost in the gap. The precondition names the harm and leaves the producer in the path.

**Fatal flaws:**
- Make the missed-write-after-upgrade impossible: a version change opens its own replay cursor at byte zero of each log, and the only resume offsets that exist are ones this replay recorded after a successful project under the new door. §3 says the transport reads from the start, then in the same breath resumes "a saved per-publisher page cursor." The incremental cursor is that saved cursor. During the mixed-version weeks it advanced through `NotAdmitted` (`absorb` in `proto/record_journal.dart` returns before `holds`). Resume from there, clear `replayPending`, and a device that can finally read the unit never holds it. Question 1's path is this coupling. No second completeness check repairs a cursor that is its own alibi.
- §3's done-condition is "every publisher's log, as listed when the replay began, absorbed to its head." That list is a phase sample on an append-only shelf. A guest vouched mid-replay (excerpt §2.5: the owner seals, the shelf stores, nobody is online together), and any page appended after the head first observed, sit outside the chord. The flag clears. The next full listen is the next version change, which may be never. "To its head" has to mean a later empty read, after the publisher list is taken again. A second tab that "skips" (§3) must have no way to retire the flag. Jitter only slides the phase: the energy is still every device times the whole log, and a replay that errors never clears, so prefix-writes become the standing wave on the morning the repair was for.
- `unknownVersion` is wired where a real next envelope cannot reach it (§2, and `Door.admit` in `proto/unit_write.dart`). The v=1 key set is enforced before `v` is read. A future wire with one foreign key — the wire §1 says must exist the day the set function or the door changes — refuses as `schema`, not as `unknownVersion`. `isNewerSchema` is then false. On a shared codraw store the stale tab's `read` throws `StateError`, `readAll` dies with it, and the update counter, which counts only newer-schema refusals, stays dark. The package-freeze sentence and the skip sentence are two tunings of one fork; the old tine snaps. `v` has to be heard before the v=1 grammar: an integer other than 1 is `unknownVersion` even when the other keys are foreign; a non-object remains corruption and still throws.
- "An editor can never mistake a newer write for absent" (§2) is true only of bytes already in the projection. Two devices, and the remote frame was `NotAdmitted` and not stored (§3, "never stores the frames"). `read` then returns `Readable` or null, and the sealed result swears the record is whole. The telling is "an app may count" refusals, in memory, optional (Named tradeoffs). A restart, or a cursor that already passed the frame, and the count is gone while the record still looks complete. Make a complete view unconstructable once any `isNewerSchema` refusal has been heard: drafts can take their `observedLive` only from a capability minted by a full view, and that capability exists only after `replayPending` has cleared with no such refusal outstanding. `UnreadWrite` must not expose a `WriteId`. The optional counter is the check that dies at 3am; delete it in favor of the type.
- Precondition 1 is unordered against the excerpt. §3.2's live channel is a relay. §3.1's shelf is the other holder. "Also posted" can follow the live send, or never happen when the sub-quota refuses the POST and leaves history (§3.5). `markAcked` (`proto/record_journal.dart`) is a watermark the transport moves when it believes delivery happened. Replay then copies the shelf perfectly and still lacks the frame every live peer already projected. The ship gate has to be an order: the shelf ack exists before the live send; a refused or unacked POST leaves the entry inside `unsent()`.

**What holds:**
- The id is the bytes. The shelf keeps the opaque history. The device stores only what its door can project. `JournalStore` gains nothing, and the held index stays dead.
- Units and families freeze whole. Carrying stays withdrawn. A new type rides a new family, so `invalidIdentity` is a broken freeze or a bad frame, and throwing there is the right loudness.
- Within v=1, `unknownFamily` and `unknownUnit` are the refusals a newer peer actually produces, and skipping those on read — while `recompute` stays strict and automatic rebuild stays out — stops a stale tab from stripping a shared projection.
- Absorb of a frame this door admits stays idempotent through `holds`, so the full re-read does not double the log.
- A write against a prefix of history coming back as a contest or a ghost is the set function doing its job. Deprecation stays "still declared, no longer written."
- Engram staying outside the claim until its own log can be read again is an honest boundary.
- The wire parse ahead of the schema parse, depth counted on the bytes first, still holds.

**If RECAST, what to fold back:**
- In §3, replace the resume sentence and the done-condition. Replay for version N has its own cursor, born at the start of each publisher log. The incremental sync cursor is not readable by that replay. A crash may resume only from offsets this replay stored after `Appended` or `AlreadyHeld` under N. Done means: list publishers, read each to an empty page, list again, and find no publisher and no page unseen. A waiting tab does not clear `replayPending`. Delete the word "skips."
- In §2, specify admit order. After the object, depth, UTF-8, and canonical tests, read `v`. An integer other than 1 is `unknownVersion` before the v=1 key set runs, foreign keys included. Only a missing or non-integer `v`, or a v=1 frame that fails the v=1 grammar, remains `schema` and still throws when stored.
- In §2 and §3, replace "may count" and the claim that the sealed result alone prevents false absence. A newer-schema `NotAdmitted` latches a partial generation. While it is latched, or while `replayPending` is set, the only view an editor can hold is partial, and `UnitWriteDraft` accepts observed ids only from a full-view capability minted after the latch clears. `UnreadWrite` carries no `WriteId`.
- In precondition 1, require the shelf's POST ack to precede any live send of that envelope, and require POST failure, including a full sub-quota, to leave the author's entry unacknowledged.
- In §1, add a package corpus: every byte string a shipped v=1 door admitted, plus fixtures for the frozen meanings of `kills`, `saw`, ghost, and contest. The snapshot sentence keeps its confession about codecs and `resolve` outside the vectors, and only about those.


