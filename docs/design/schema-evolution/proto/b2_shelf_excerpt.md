# Excerpt: codraw B2 DESIGN, sections 2.4 to 3.5

Source: enspyrco/codraw, branch docs/canvas-sync-order-authority, docs/crucible/canvas-sync-order-authority/DESIGN.md lines 205-285.


### 2.4 Who checks what

| Check | Reader | Shelf |
|---|---|---|
| `sig`, strict cofactorless Ed25519 | yes | yes |
| `vouchSig` over `signed.canvasNs ‖ signed.publisherPub` by the owner key | yes, against `o` | yes, against the door's registered `ownerPub` |
| frames: strict UTF-8, the §1.1 grammar, canonical form, identity derivation, the set function | yes | no |
| per-publisher byte sub-quota (§3.5) | no | yes |

**C7, restated: the shelf holds bytes and decides nothing semantic.** It refuses envelopes that fail signature or
quota; it never refuses on order, content or time.

### 2.5 The guest, and the vouch's way home (disposition 9)

1. The guest draws into their journal, and nothing is sealed.
2. A knock delivers `publisherPub`, live or through the per-door knock list (V3).
3. **An owner device approves by sealing an envelope at once whose only frame is the tag-1 vouch certificate**
   (B2b 9, Noether), encrypted under `K`. The vouch no longer waits for the owner's next drawing. The shelf stores it
   as opaque bytes, and its index lists it under the owner's publisher. An envelope with no tag-0 frame is
   legal: the no-kill-only rule (R13) is about unit writes, and this envelope carries none.
4. The guest's device reads every publisher's log anyway, so it finds the frame naming its own `publisherPub`. It
   then seals and posts its records with the vouch inside each `signed`.

**[Fold H3]** A tag-1 frame counts only under the owner's signature, wherever it rides. Readers ignore an
invalid one and still admit the envelope's other frames.

**Nobody has to be online at the same time as anyone else.** The guest's waiting edits to existing objects arrive as
races: **drawn beside the values they raced, and listed on the conflict surface** (§3.6).

### 2.6 Agents

An agent is a vouched publisher and comes in through the same knock. **A publisher writing to existing units must
hold a synced projection,** because its `kills` must be what it saw. A blind writer's `kills = []` is a race by
construction (disposition 4). ADR-0003's labels-not-geometry rule is the agent's own restraint, as today (T7).

## 3. Transport, recovery, presentation

### 3.1 Shelves

Two independent holders. POST checks the signature, `vouchSig` and the sub-quota. GET serves the paged
per-publisher index and entries by id. Registration happens at creation.

### 3.2 The live channel

The LiveKit data channel carries envelopes in the same bytes through the same door. Mid-gesture strokes stay
presence. It is a relay, not a database.

### 3.3 Share

Copying the link is gated on reading back an index of everything this device holds, from both shelves (V2).

### 3.4 Import and recovery (dispositions 4, 5, 7)

- **Archive v2 (V4), now inside step 1:** the archive carries unit-write bytes. Merge replays them verbatim, so the
  `writeId`s are identical and dead stays dead.
- **v1 archives:** each object maps through the v1-import row of §1.3, with a deterministic id. Each unit is
  re-minted with a fresh salt and `kills = []`. **The archive's time is not read:** the v1-import clamp is deleted
  with `claimed`, and `GraphIngress`'s clock judge stays deleted. G3's strict parse of v1 time has no B2 reader. It
  survives only as task #24's fix to today's pre-B2 importer, and leaves with step 1.
- **The importer emits no write whose fields are already among the unit's shown values** (canonical bytes, which
  are stable now). That mirrors `update_entity_middleware.dart:59–60`. An unchanged unit costs nothing and lists
  nothing.
- **[Fold H1] `GraphIngress`'s stamp checks go with its clock judge** (`graph_ingress.dart:120–131`). With the
  `stamps` view deleted, they would refuse every object. Under B2, v1 `hlc` strings are read by nothing, and v2
  frames by §1.1's door.
- **Restore** asserts `_tomb = false` only, with `kills` = the observed live set of `_tomb`. Content follows Merge.
  It stays non-destructive (`canvas_importer.dart:94–137`).
- **T5 is reduced to:** a v1 re-mint whose value is not among the shown ones, against a history the archive
  pre-dates. It shows as a race on the conflict surface.

### 3.5 Sizes and quotas (disposition 6)

- **Hop limits are named, and `B` is derived from the smallest:**
  - the shelf's POST body limit (**1 MiB**, set by us);
  - the LiveKit reliable data-message limit (**measured at step 5, not assumed**);
  - one sembast transaction per chain link.
- **Sub-quotas.** Each vouched publisher has its own byte sub-quota per door, counted by the shelf, which is storage
  policy and not authority. A flood spends only the flooder's slice, so honest repairs draw on honest slices.
  **Vouches are owner-minted, which is what makes a slice scarce.**
- **The door total** stays V1, Nick's call before step 6.
