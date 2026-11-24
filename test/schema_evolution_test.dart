// Two builds over one store, where the newer one added a unit to `note` and a
// whole family: the older build leaves out what it can't read and says so
// (schema-evolution DESIGN §2).
import 'dart:math';

import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'fixtures/mint.dart';
import 'fixtures/notes.dart';

final _color = UnitName.of('color');

/// `note` as the newer build declares it: one unit more, nothing changed.
final _newerNoteFamily = HashedIdentityFamily(
    name: FamilyName.of('note'),
    schema: RecordSchema(type: RecordType.of('note'), units: {
      body: fieldNames(['text', 'n', 'tags']),
      title: fieldNames(['title']),
      _color: fieldNames(['hex']),
    }),
    fields: {FieldName.of('nonce')});

/// A family only the newer build has.
final _stickerFamily = HashedIdentityFamily(
    name: FamilyName.of('sticker'),
    schema: RecordSchema(type: RecordType.of('sticker'), units: {
      body: fieldNames(['emoji']),
    }),
    fields: {FieldName.of('nonce')});

/// `note` with a field added to a shipped unit: what the freeze forbids.
final _freezeBreakingNoteFamily = HashedIdentityFamily(
    name: FamilyName.of('note'),
    schema: RecordSchema(type: RecordType.of('note'), units: {
      body: fieldNames(['text', 'n', 'tags', 'font']),
      title: fieldNames(['title']),
    }),
    fields: {FieldName.of('nonce')});

RecordJournal _older(JournalStore s) =>
    RecordJournal(store: s, families: [noteFamily], random: Random(1));

RecordJournal _newer(JournalStore s) => RecordJournal(
    store: s, families: [_newerNoteFamily, _stickerFamily], random: Random(2));

Identity _sticker(String nonce) =>
    Identity.of(FamilyName.of('sticker'), {'nonce': nonce});

void main() {
  final a = note('a');
  final aId = noteDoor.resolve(a)!.id;

  Future<(RecordJournal, RecordJournal, WriteId, WriteId)> extended() async {
    final store = InMemoryJournalStore();
    final older = _older(store);
    final newer = _newer(store);
    final [b] = await older.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    final [c] = await newer.write([
      UnitWriteDraft.content(
          identity: a, unit: _color, fields: {'hex': '#f00'}, observedLive: {}),
    ]);
    return (older, newer, b, c);
  }

  test('an older build reads what it can and lists the rest as unread',
      () async {
    final (older, newer, b, _) = await extended();
    final view = await readableOf(older, aId);
    expect(view.units.keys, {body});
    expect(view.units[body]!.liveIds, {b});
    expect(view.unread.single.reason, Refusal.unknownUnit);
    expect(view.liveContentIds, {b},
        reason: 'a delete computed here can only see what was read');

    final whole = (await viewOf(newer, aId))!;
    expect(whole.units.keys, {body, _color});
  });

  test('a record only a newer build can read is unread, never absent',
      () async {
    final store = InMemoryJournalStore();
    final s = _sticker('s1');
    await _newer(store).write([
      UnitWriteDraft.content(
          identity: s, unit: body, fields: {'emoji': '*'}, observedLive: {}),
    ]);
    final sId = Door([_stickerFamily]).resolve(s)!.id;
    final older = _older(store);
    expect(
        await older.read(sId),
        isA<UnreadRecord>().having(
            (r) => r.unread.single.reason, 'reason', Refusal.unknownFamily));
    expect(await older.readAll(), [isA<UnreadRecord>()]);
  });

  test('an older delete leaves a ghost over the unit it never saw', () async {
    final (older, newer, _, c) = await extended();
    final view = await readableOf(older, aId);
    await older.write([
      UnitWriteDraft.delete(
          identity: a,
          observedLiveTomb: view.tomb?.liveIds ?? {},
          sawContent: view.liveContentIds),
    ]);
    expect(await viewOf(newer, aId),
        isA<GhostRecord>().having((g) => g.unseen, 'unseen', {c}));
  });

  test(
      'a stored write refused for another reason throws on read, and only '
      'marks its own record in readAll', () async {
    final store = InMemoryJournalStore();
    final breaking = RecordJournal(
        store: store, families: [_freezeBreakingNoteFamily], random: Random(3));
    await breaking.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'font': 'serif'}, observedLive: {}),
    ]);
    final older = _older(store);
    final other = note('b');
    await older.write([
      UnitWriteDraft.content(
          identity: other, unit: body, fields: {'text': 'y'}, observedLive: {}),
    ]);

    await expectLater(older.read(aId), throwsStateError);
    final all = await older.readAll();
    expect(all.map((r) => r.id),
        unorderedEquals([aId, noteDoor.resolve(other)!.id]));
    expect(
        all.whereType<UnreadableRecord>().single,
        isA<UnreadableRecord>()
            .having((r) => r.id, 'id', aId)
            .having((r) => r.reason, 'reason', Refusal.fields));
    expect(all.whereType<Readable>(), hasLength(1));
  });

  test('recompute in an older build throws and changes nothing', () async {
    final (older, newer, _, _) = await extended();
    final before = describe((await viewOf(newer, aId))!);
    await expectLater(older.recompute(), throwsStateError);
    expect(describe((await viewOf(newer, aId))!), before);
  });

  test('an older build refuses a newer frame as newer, and stores nothing',
      () async {
    final store = InMemoryJournalStore();
    final newer = _newer(InMemoryJournalStore());
    await newer.write([
      UnitWriteDraft.content(
          identity: a, unit: _color, fields: {'hex': '#0f0'}, observedLive: {}),
    ]);
    final older = _older(store);
    expect(
        await older.absorb((await newer.unsent()).single.bytes),
        isA<NotAdmitted>()
            .having((r) => r.refused.reason, 'reason', Refusal.unknownUnit));
    expect(await older.readAll(), isEmpty);
  });

  test('only the three newer-schema refusals make an UnreadWrite', () {
    final id = WriteId.ofBytes([0x7B]);
    for (final reason in Refusal.values) {
      UnreadWrite make() => UnreadWrite.of(Refused(id, reason));
      if (reason.isNewerSchema) {
        expect(make(), isA<UnreadWrite>());
      } else {
        expect(make, throwsArgumentError, reason: '$reason');
      }
    }
    expect(Refusal.values.where((r) => r.isNewerSchema),
        {Refusal.unknownFamily, Refusal.unknownUnit, Refusal.unknownVersion});
  });
}
