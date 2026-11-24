import 'dart:math';

import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'fixtures/mint.dart';
import 'fixtures/notes.dart';

void main() {
  final a = note('a');
  late Minter m;
  setUp(() => m = Minter());

  RecordView view(Iterable<UnitWrite> ws) => RecordView.of(ws);
  UnitState unit(Iterable<UnitWrite> ws, UnitName u) => view(ws).units[u]!;

  group('the value of a unit (§1.2)', () {
    test('one write is the value', () {
      final w = m.edit(a, body, {'text': 'x'});
      final s = unit([w], body);
      expect(s.live, {w});
      expect(s.shown.single.text, '{"text":"x"}');
      expect(s.contested, isFalse);
    });

    test('C8: a causal pair resolves exactly', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'y'}, {w1});
      expect(unit([w1, w2], body).live, {w2});
    });

    test('C5, C8: a concurrent pair with distinct values shows both', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'y'}, {w1});
      final w3 = m.edit(a, body, {'text': 'z'}, {w1});
      final s = unit([w1, w2, w3], body);
      expect(s.live, {w2, w3});
      expect(s.contested, isTrue);
      expect(
          [for (final f in s.shown) f.text], ['{"text":"y"}', '{"text":"z"}'],
          reason: 'shown iterates in canonical order');
    });

    test('equal values do not compete', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'same'}, {w1});
      final w3 = m.edit(a, body, {'text': 'same'}, {w1});
      final s = unit([w1, w2, w3], body);
      expect(s.live, {w2, w3}, reason: 'different salts: two writes');
      expect(s.contested, isFalse);
    });

    test('C3: one write naming the live set settles a race', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'y'});
      final settle = m.edit(a, body, {'text': 'y'}, {w1, w2});
      final s = unit([w1, w2, settle], body);
      expect(s.live, {settle});
      expect(s.contested, isFalse);
    });

    test('C4: a kill naming an absent write lands when it arrives', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'y'}, {w1});
      expect(unit([w2], body).live, {w2});
      expect(unit([w2, w1], body).live, {w2});
    });

    test('kills act only within their own (record, unit)', () {
      final b1 = m.edit(a, body, {'text': 'x'});
      // A title write that names the body write kills nothing in body.
      final t = m.admit(UnitWriteDraft.content(
          identity: a,
          unit: title,
          fields: {'title': 't'},
          observedLive: {b1.id}));
      expect(unit([b1, t], body).live, {b1});
    });

    test('a unit is taken whole: an omitted field is a different value', () {
      final w1 = m.edit(a, body, {'text': 'x', 'n': 1});
      final w2 = m.edit(a, body, {'text': 'x'});
      expect(unit([w1, w2], body).contested, isTrue);
    });

    test('C12: salt makes equal drafts distinct writes', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'x'});
      expect(w1.id, isNot(w2.id));
    });

    test('a deterministic birth is one write from any device', () {
      final id = Identity.of(FamilyName.of('derivedNote'), {'cause': 'c'});
      UnitWrite birth(int seed) =>
          Minter(seed).admit(UnitWriteDraft.deterministicBirth(
              identity: id, unit: body, fields: {'text': 'again'}));
      expect(birth(1).bytes, birth(2).bytes);
      expect(birth(1).id, birth(2).id);
    });

    test('a draft keeps what its author saw, whatever happens to the set', () {
      final w1 = m.edit(a, body, {'text': 'x'});
      final w2 = m.edit(a, body, {'text': 'y'});
      final observed = {w1.id};
      final draft = UnitWriteDraft.content(
          identity: a,
          unit: body,
          fields: {'text': 'z'},
          observedLive: observed);
      observed.add(w2.id);
      final written = m.admit(draft);
      expect(written.kills, {w1.id});
    });

    test('a write-once unit with two births is shown, not listed as a race',
        () {
      final schema = RecordSchema(type: RecordType.of('once'), units: {
        body: fieldNames(['text']),
      }, writeOnce: {
        body
      });
      final family = HashedIdentityFamily(
          name: FamilyName.of('once'),
          schema: schema,
          fields: {FieldName.of('nonce')});
      final door = Door([family]);
      final id = Identity.of(FamilyName.of('once'), {'nonce': 'o'});
      final births = [
        for (final t in ['x', 'y'])
          m.admit(
              UnitWriteDraft.content(
                  identity: id,
                  unit: body,
                  fields: {'text': t},
                  observedLive: {}),
              door: door),
      ];
      final v = view(births);
      expect(v.units[body]!.contested, isTrue);
      expect(v.units[body]!.shown, hasLength(2));
      expect(v.contestedUnits, isEmpty, reason: 'no write can settle it');
    });

    test('a field nests as deep as a write allows, and no deeper', () {
      Object? nest(int depth) => depth == 0 ? 1 : [nest(depth - 1)];
      expect(canonicalJsonOrNull(nest(maxNestingDepth)), isNotNull);
      expect(canonicalJsonOrNull(nest(maxNestingDepth + 1)), isNull);
      // The write object and its fields object take two levels of the frame.
      final deepest = m.edit(a, body, {'n': nest(maxNestingDepth - 2)});
      expect(noteDoor.admit(deepest.bytes), isA<Admitted>());
      // The constructor alone, so a refusal at encode or at the door can't
      // stand in for it.
      expect(
          () => UnitWriteDraft.content(
              identity: a,
              unit: body,
              fields: {'n': nest(maxNestingDepth - 1)},
              observedLive: {}),
          throwsArgumentError,
          reason: 'refused when drafted, not at write time');
    });

    test('a double cannot be drafted', () {
      expect(() => m.edit(a, body, {'n': 0.5}), throwsArgumentError);
    });
  });

  group('delete versus edit, D1 (§3.6.5, C14)', () {
    late UnitWrite b1, t1;
    setUp(() {
      b1 = m.edit(a, body, {'text': 'x'});
      t1 = m.edit(a, title, {'title': 't'});
    });

    test('no _tomb write: drawn', () {
      expect(view([b1, t1]), isA<DrawnRecord>());
    });

    test('a delete that saw every live content write hides', () {
      final d = m.delete(a, content: {b1, t1});
      expect(view([b1, t1, d]), isA<HiddenRecord>());
    });

    test('a concurrent edit the delete never saw makes a listed ghost', () {
      final d = m.delete(a, content: {b1, t1});
      final moved = m.edit(a, body, {'text': 'moved'}, {b1});
      final v = view([b1, t1, d, moved]);
      expect(v, isA<GhostRecord>());
      v as GhostRecord;
      expect(v.unseen, {moved.id});
      expect(v.tombContested, isFalse);
    });

    test('a write to a unit the record lacked at delete makes a ghost', () {
      final d = m.delete(a, content: {b1});
      final v = view([b1, d, t1]);
      expect(v, isA<GhostRecord>());
      expect((v as GhostRecord).unseen, {t1.id});
    });

    test('saw is a witness, not a kill: it empties no unit', () {
      final d = m.delete(a, content: {b1, t1});
      final v = view([b1, t1, d]);
      expect(v.units[body]!.live, {b1});
      expect(v.units[title]!.live, {t1});
    });

    test('restore brings back every live content write, the unseen included',
        () {
      final d = m.delete(a, content: {b1, t1});
      final moved = m.edit(a, body, {'text': 'moved'}, {b1});
      final r = m.restore(a, tomb: {d});
      final v = view([b1, t1, d, moved, r]);
      expect(v, isA<DrawnRecord>());
      expect(v.units[body]!.live, {moved});
      expect(v.units[title]!.live, {t1});
    });

    test('a fresh delete over the ghost hides it', () {
      final d = m.delete(a, content: {b1, t1});
      final moved = m.edit(a, body, {'text': 'moved'}, {b1});
      final ghost = view([b1, t1, d, moved]);
      final d2 = m.admit(UnitWriteDraft.delete(
          identity: a,
          observedLiveTomb: ghost.tomb!.liveIds,
          sawContent: ghost.liveContentIds));
      expect(view([b1, t1, d, moved, d2]), isA<HiddenRecord>());
    });

    test('concurrent deletes witness by union', () {
      final d1 = m.delete(a, content: {b1});
      final d2 = m.delete(a, content: {t1});
      expect(view([b1, t1, d1, d2]), isA<HiddenRecord>());
    });

    test('_tomb contested between delete and restore: a ghost', () {
      final d = m.delete(a, content: {b1, t1});
      final r = m.restore(a);
      final v = view([b1, t1, d, r]);
      expect(v, isA<GhostRecord>());
      v as GhostRecord;
      expect(v.tombContested, isTrue);
      expect(v.unseen, isEmpty);
    });

    test('concurrent restores are equal values, not a race', () {
      final d = m.delete(a, content: {b1, t1});
      final r1 = m.restore(a, tomb: {d});
      final r2 = m.restore(a, tomb: {d});
      final v = view([b1, t1, d, r1, r2]);
      expect(v, isA<DrawnRecord>());
      expect(v.tomb!.contested, isFalse);
    });

    test('a delete of a record with no content hides it', () {
      expect(view([m.delete(a)]), isA<HiddenRecord>());
    });
  });

  group('C1, C10: a view is a function of the set', () {
    test('order and duplication never change a view', () {
      final rng = Random(7);
      for (var round = 0; round < 60; round++) {
        final writes = _history(Minter(round), rng);
        final expected = describe(view(writes));
        for (var k = 0; k < 8; k++) {
          final shuffled = [
            ...writes,
            for (var i = 0; i < rng.nextInt(writes.length); i++)
              writes[rng.nextInt(writes.length)],
          ]..shuffle(rng);
          expect(describe(view(shuffled)), expected);
        }
      }
    });

    test('no admitted write makes a view throw; live is exactly the unkilled',
        () {
      final rng = Random(11);
      var absentKills = 0;
      for (var round = 0; round < 200; round++) {
        final writes = _history(Minter(1000 + round), rng);
        final ids = {for (final w in writes) w.id};
        final v = view(writes);
        for (final MapEntry(key: u, value: s) in v.units.entries) {
          final ofUnit = [
            for (final w in writes)
              if (w.unit == u) w
          ];
          final named = {for (final w in ofUnit) ...w.kills};
          absentKills += named.where((k) => !ids.contains(k)).length;
          expect(s.live, {
            for (final w in ofUnit)
              if (!named.contains(w.id)) w
          });
          expect(s.live, isNotEmpty);
          expect(s.shown, {for (final w in s.live) w.fields});
        }
      }
      expect(absentKills, greaterThan(0),
          reason: 'the histories must name undelivered writes');
    });
  });
}

/// A random history on one record: edits, deletes and restores, each seeing a
/// random subset of what was authored before it (including nothing). Some
/// writes are never delivered, so delivered writes can name absent ones (C4).
List<UnitWrite> _history(Minter m, Random rng) {
  final id = note('p');
  final authored = <UnitWrite>[];
  final all = <UnitWrite>[];
  Set<UnitWrite> someOf(UnitName u) => {
        for (final w in authored)
          if (w.unit == u && rng.nextBool()) w,
      };
  final n = 2 + rng.nextInt(14);
  for (var i = 0; i < n; i++) {
    final w = switch (rng.nextInt(5)) {
      0 || 1 => m.edit(id, body, {'text': 'v${rng.nextInt(3)}'}, someOf(body)),
      2 => m.edit(id, title, {'title': 't${rng.nextInt(2)}'}, someOf(title)),
      3 => m.delete(id,
          tomb: someOf(UnitName.tomb),
          content: {...someOf(body), ...someOf(title)}),
      _ => m.restore(id, tomb: someOf(UnitName.tomb)),
    };
    authored.add(w);
    if (rng.nextInt(6) > 0) all.add(w);
  }
  if (all.isEmpty) all.add(m.edit(id, body, {'text': 'only'}));
  return all;
}
