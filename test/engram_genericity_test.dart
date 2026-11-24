// The genericity test: engram's seven record types declared without canvas
// vocabulary, and the cases its table calls out.
import 'dart:math';

import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'fixtures/engram.dart';

RecordJournal _device(int seed) => RecordJournal(
    store: InMemoryJournalStore(),
    families: engramFamilies,
    random: Random(seed));

final _door = Door(engramFamilies);
RecordId _id(Identity i) => _door.resolve(i)!.id;
UnitName _u(String n) => UnitName.of(n);

void main() {
  test('every type takes a write and reads back', () async {
    final j = _device(1);
    final writes = {
      Identity.of(FamilyName.of('concept'), {'nonce': 'c1'}): (
        'body',
        {
          'name': 'Spaced repetition',
          'description': null,
          'sourceDocumentId': 'outline-doc-7',
          'tags': ['memory', 'learning'],
          'parentConceptId': null,
        }
      ),
      Identity.of(FamilyName.of('relationship'), {'nonce': 'r1'}): (
        'body',
        {
          'from': 'c1',
          'to': 'c2',
          'label': 'depends on',
          'description': null,
          'type': 'prerequisite',
        }
      ),
      Identity.of(FamilyName.of('quizItem'), {'nonce': 'q1'}): (
        'content',
        {
          'conceptId': 'c1',
          'question': 'Why space reviews?',
          'answer': 'Forgetting curve',
          'rubric': null,
        }
      ),
      Identity.of(FamilyName.of('review'), {'nonce': 'rv1'}): (
        'event',
        {
          'quizItemId': 'q1',
          'rating': 3,
          'reviewedAt': 1764000000000,
          // 0.9 at engram's ×10000 fixed point: the wire carries no doubles.
          'desiredRetention': 9000,
        }
      ),
      Identity.of(FamilyName.of('document'), {'outlineId': 'outline-doc-7'}): (
        'ingest',
        {
          'title': 'Memory',
          'updatedAt': 1764000000000,
          'ingestedAt': 1764000100000,
          'ingestedText': '…',
        }
      ),
      Identity.of(FamilyName.of('topic'), {'nonce': 't1'}): (
        'name',
        {'name': 'Learning'}
      ),
    };
    await j.write([
      for (final MapEntry(key: id, value: (unit, fields)) in writes.entries)
        UnitWriteDraft.content(
            identity: id, unit: _u(unit), fields: fields, observedLive: {}),
    ]);
    final views = await j.readAll();
    expect({for (final v in views) v.schema.type.value},
        {'concept', 'relationship', 'quizItem', 'review', 'document', 'topic'});
    expect(views.every((v) => v is DrawnRecord), isTrue);
  });

  test('a document is keyed by its Outline id', () {
    expect(
        _id(Identity.of(
            FamilyName.of('document'), {'outlineId': 'outline-doc-7'})),
        RecordId(FamilyName.of('document'), RecordKey.of('outline-doc-7')));
  });

  test('ids from different families never collide, whatever the keys', () {
    // The document family's key is the raw Outline id, so it can spell the
    // topicDocument family's key for (t1, d1) exactly.
    final doc =
        Identity.of(FamilyName.of('document'), {'outlineId': '2:t1:d1'});
    final link = Identity.of(
        FamilyName.of('topicDocument'), {'topicId': 't1', 'documentId': 'd1'});
    expect(_id(doc).key, _id(link).key);
    expect(_id(doc), isNot(_id(link)));
  });

  test('a record id round-trips through its storage key', () {
    final id = RecordId(FamilyName.of('a:b'), RecordKey.of('["x"]'));
    expect(RecordId.parseStorageKey(id.storageKey), id);
    expect('$id', id.storageKey);
  });

  test('only names a store can key on exist', () {
    final lone = String.fromCharCode(0xD800);
    expect(RecordKey.parse(lone), isNull);
    expect(FamilyName.parse(lone), isNull);
    expect(RecordType.parse(lone), isNull);
    expect(RecordKey.parse(''), isNull);
    expect(FamilyName.parse(''), isNull);
    expect(() => RecordKey.of(lone), throwsArgumentError);
  });

  test('a hashed family cannot claim the identity field "family"', () {
    expect(
        () => HashedIdentityFamily(
            name: FamilyName.of('f'),
            schema: topicDocument,
            fields: {FieldName.of('family')}),
        throwsArgumentError);
  });

  test('a malformed storage key reads as null, never a throw', () {
    final esc = String.fromCharCode(0x5C);
    for (final text in [
      '[ "a","b"]',
      '["a"]',
      '["","b"]',
      '["a","${esc}ud800"]',
      '["a",${'[' * 20000}${']' * 20000}]',
      'not json',
    ]) {
      expect(RecordId.parseStorageKey(text), isNull, reason: text);
    }
  });

  test('ids that print alike are the same id', () {
    final a = RecordId(FamilyName.of('document/foo'), RecordKey.of('bar'));
    final b = RecordId(FamilyName.of('document'), RecordKey.of('foo/bar'));
    expect('$a', isNot('$b'));
  });

  test('a schema cannot declare _tomb', () {
    expect(
        () =>
            RecordSchema(type: RecordType.of('t'), units: {UnitName.tomb: {}}),
        throwsArgumentError);
  });

  test('a topicDocument is a composite id, and the composite is injective', () {
    Identity td(String t, String d) => Identity.of(
        FamilyName.of('topicDocument'), {'topicId': t, 'documentId': d});
    expect(_id(td('a__b', 'c')), isNot(_id(td('a', 'b__c'))));
    expect(_id(td('t1', 'd1')), _id(td('t1', 'd1')));
  });

  test('a topicDocument lives in _tomb: born by restore, gone by delete',
      () async {
    final j = _device(1);
    final link = Identity.of(FamilyName.of('topicDocument'),
        {'topicId': 't1', 'documentId': 'outline-doc-7'});
    await j.write([
      UnitWriteDraft.restore(identity: link, observedLiveTomb: {}),
    ]);
    final born = (await j.read(_id(link)))!;
    expect(born, isA<DrawnRecord>());
    await j.write([
      UnitWriteDraft.delete(
          identity: link,
          observedLiveTomb: born.tomb!.liveIds,
          sawContent: born.liveContentIds),
    ]);
    expect(await j.read(_id(link)), isA<HiddenRecord>());
  });

  test('two devices adding one document to one topic do not race', () async {
    final link = Identity.of(FamilyName.of('topicDocument'),
        {'topicId': 't1', 'documentId': 'outline-doc-7'});
    final alice = _device(1);
    final bob = _device(2);
    for (final d in [alice, bob]) {
      await d.write(
          [UnitWriteDraft.restore(identity: link, observedLiveTomb: {})]);
    }
    await alice.absorb((await bob.unsent()).single.bytes);
    final v = (await alice.read(_id(link)))!;
    expect(v.tomb!.live, hasLength(2));
    expect(v.tomb!.contested, isFalse);
  });

  test('a review is write-once: a second write to it is refused', () async {
    final j = _device(1);
    final rv = Identity.of(FamilyName.of('review'), {'nonce': 'rv1'});
    final fields = {
      'quizItemId': 'q1',
      'rating': 3,
      'reviewedAt': 1,
      'desiredRetention': 9000,
    };
    await j.write([
      UnitWriteDraft.content(
          identity: rv, unit: _u('event'), fields: fields, observedLive: {}),
    ]);
    final seen = (await j.read(_id(rv)))!.units[_u('event')]!.liveIds;
    await expectLater(
        j.write([
          UnitWriteDraft.content(
              identity: rv,
              unit: _u('event'),
              fields: {...fields, 'rating': 1},
              observedLive: seen),
        ]),
        throwsArgumentError);
  });

  test('the synthetic Again: two devices mint one write', () async {
    final newContent = {'question': 'Why?', 'answer': 'Changed'};
    final again = syntheticAgain('q1', newContent);
    final event = {
      'quizItemId': 'q1',
      'rating': 1,
      'reviewedAt': 0,
      'desiredRetention': 9000,
    };
    final alice = _device(1);
    final bob = _device(2);
    final [a] = await alice.write([
      UnitWriteDraft.deterministicBirth(
          identity: again, unit: _u('event'), fields: event),
    ]);
    final [b] = await bob.write([
      UnitWriteDraft.deterministicBirth(
          identity: again, unit: _u('event'), fields: event),
    ]);
    expect(a, b);
    await alice.absorb((await bob.unsent()).single.bytes);
    final v = (await alice.read(_id(again)))!;
    expect(v.units[_u('event')]!.live, hasLength(1), reason: 'one lapse');
  });

  test('a real review may not be minted deterministically', () async {
    await expectLater(
        _device(1).write([
          UnitWriteDraft.deterministicBirth(
              identity: Identity.of(FamilyName.of('review'), {'nonce': 'rv1'}),
              unit: _u('event'),
              fields: {
                'quizItemId': 'q1',
                'rating': 3,
                'reviewedAt': 0,
                'desiredRetention': 9000,
              }),
        ]),
        throwsArgumentError);
  });

  test('predicted written once per device shows both; the package never picks',
      () async {
    final q = Identity.of(FamilyName.of('quizItem'), {'nonce': 'q1'});
    final alice = _device(1);
    final bob = _device(2);
    await alice.write([
      UnitWriteDraft.content(
          identity: q,
          unit: _u('predicted'),
          fields: {'predictedDifficulty': 420},
          observedLive: {}),
    ]);
    await bob.write([
      UnitWriteDraft.content(
          identity: q,
          unit: _u('predicted'),
          fields: {'predictedDifficulty': 610},
          observedLive: {}),
    ]);
    await alice.absorb((await bob.unsent()).single.bytes);
    final s = (await alice.read(_id(q)))!.units[_u('predicted')]!;
    expect(s.contested, isTrue);
    // The package never picks; engram's fold reads the integers and takes the
    // max, so a harder prior shows the card sooner.
    expect(
        s.shown.map((f) => f.json.integer('predictedDifficulty')).reduce(max),
        610);
  });

  test('shown orders by canonical text, which is not numeric order', () {
    // Difficulty 10.0 and 9.99 at ×100: "1000" sorts before "999". The order
    // is deterministic, which is all a fold needs, but it is not "smallest".
    final m = Door(engramFamilies);
    final q = Identity.of(FamilyName.of('quizItem'), {'nonce': 'q1'});
    UnitWrite w(int d, int seed) => switch (m.admit(UnitWriteDraft.content(
            identity: q,
            unit: _u('predicted'),
            fields: {'predictedDifficulty': d},
            observedLive: {}).encode(Salt.random(Random(seed))))) {
          Admitted(:final write) => write,
          Refused(:final reason) => throw StateError('$reason'),
        };
    final s = UnitState.of([w(999, 1), w(1000, 2)]);
    expect([for (final f in s.shown) f.json.integer('predictedDifficulty')],
        [1000, 999]);
  });

  test('a double is refused before it is drafted', () {
    expect(
        () => UnitWriteDraft.content(
            identity: Identity.of(FamilyName.of('review'), {'nonce': 'rv1'}),
            unit: _u('event'),
            fields: {'desiredRetention': 0.9},
            observedLive: {}),
        throwsArgumentError);
  });
}
