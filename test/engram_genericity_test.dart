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
      Identity.of('concept', {'nonce': 'c1'}): (
        'body',
        {
          'name': 'Spaced repetition',
          'description': null,
          'sourceDocumentId': 'outline-doc-7',
          'tags': ['memory', 'learning'],
          'parentConceptId': null,
        }
      ),
      Identity.of('relationship', {'nonce': 'r1'}): (
        'body',
        {
          'from': 'c1',
          'to': 'c2',
          'label': 'depends on',
          'description': null,
          'type': 'prerequisite',
        }
      ),
      Identity.of('quizItem', {'nonce': 'q1'}): (
        'content',
        {
          'conceptId': 'c1',
          'question': 'Why space reviews?',
          'answer': 'Forgetting curve',
          'rubric': null,
        }
      ),
      Identity.of('review', {'nonce': 'rv1'}): (
        'event',
        {
          'quizItemId': 'q1',
          'rating': 3,
          'reviewedAt': 1764000000000,
          // 0.9 at engram's ×10000 fixed point: the wire carries no doubles.
          'desiredRetention': 9000,
        }
      ),
      Identity.of('document', {'outlineId': 'outline-doc-7'}): (
        'ingest',
        {
          'title': 'Memory',
          'updatedAt': 1764000000000,
          'ingestedAt': 1764000100000,
          'ingestedText': '…',
        }
      ),
      Identity.of('topic', {'nonce': 't1'}): ('name', {'name': 'Learning'}),
    };
    await j.write([
      for (final MapEntry(key: id, value: (unit, fields)) in writes.entries)
        UnitWriteDraft.content(
            identity: id, unit: _u(unit), fields: fields, observedLive: {}),
    ]);
    final views = await j.readAll();
    expect({for (final v in views) v.schema.type},
        {'concept', 'relationship', 'quizItem', 'review', 'document', 'topic'});
    expect(views.every((v) => v is DrawnRecord), isTrue);
  });

  test('a document is keyed by its Outline id', () {
    expect(_id(Identity.of('document', {'outlineId': 'outline-doc-7'})),
        RecordId.of('outline-doc-7'));
  });

  test('a topicDocument is a composite id, and the composite is injective', () {
    Identity td(String t, String d) =>
        Identity.of('topicDocument', {'topicId': t, 'documentId': d});
    expect(_id(td('a__b', 'c')), isNot(_id(td('a', 'b__c'))));
    expect(_id(td('t1', 'd1')), _id(td('t1', 'd1')));
  });

  test('a topicDocument lives in _tomb: born by restore, gone by delete',
      () async {
    final j = _device(1);
    final link = Identity.of(
        'topicDocument', {'topicId': 't1', 'documentId': 'outline-doc-7'});
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
    final link = Identity.of(
        'topicDocument', {'topicId': 't1', 'documentId': 'outline-doc-7'});
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
    final rv = Identity.of('review', {'nonce': 'rv1'});
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
              identity: Identity.of('review', {'nonce': 'rv1'}),
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
    final q = Identity.of('quizItem', {'nonce': 'q1'});
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
    // Engram's fold takes the first: the smallest canonical text.
    expect(s.shown.first.json.integer('predictedDifficulty'), 420);
  });

  test('shown orders by canonical text, which is not numeric order', () {
    // Difficulty 10.0 and 9.99 at ×100: "1000" sorts before "999". The order
    // is deterministic, which is all a fold needs, but it is not "smallest".
    final m = Door(engramFamilies);
    final q = Identity.of('quizItem', {'nonce': 'q1'});
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
            identity: Identity.of('review', {'nonce': 'rv1'}),
            unit: _u('event'),
            fields: {'desiredRetention': 0.9},
            observedLive: {}),
        throwsArgumentError);
  });
}
