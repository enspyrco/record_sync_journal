import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'fixtures/mint.dart';
import 'fixtures/notes.dart';

RecordJournal _journal(JournalStore store, {int seed = 1}) => RecordJournal(
    store: store,
    families: [noteFamily, derivedNoteFamily],
    random: Random(seed));

Future<String> _snapshot(RecordJournal j) async =>
    (await j.readAll()).map(describe).join('\n\n');

void main() {
  final a = note('a');
  final aId = noteDoor.resolve(a)!.id;

  test('a write is read back as its view', () async {
    final j = _journal(InMemoryJournalStore());
    final [w] = await j.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    final v = (await j.read(aId))!;
    expect(v, isA<DrawnRecord>());
    expect(v.units[body]!.liveIds, {w});
    expect(v.id, aId);
  });

  test('an edit kills the live set its caller observed', () async {
    final j = _journal(InMemoryJournalStore());
    await j.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    final observed = (await j.read(aId))!.units[body]!.liveIds;
    final [w2] = await j.write([
      UnitWriteDraft.content(
          identity: a,
          unit: body,
          fields: {'text': 'y'},
          observedLive: observed),
    ]);
    expect((await j.read(aId))!.units[body]!.liveIds, {w2});
  });

  test('a refused draft stores nothing, even beside a good one', () async {
    final store = InMemoryJournalStore();
    final j = _journal(store);
    final good = UnitWriteDraft.content(
        identity: a, unit: body, fields: {'text': 'x'}, observedLive: {});
    final unknown = UnitWriteDraft.content(
        identity: Identity.of('nope', {'nonce': 'n'}),
        unit: body,
        fields: {},
        observedLive: {});
    await expectLater(j.write([good, unknown]), throwsArgumentError);
    expect(await j.readAll(), isEmpty);
    expect(await j.unsent(), isEmpty);
  });

  test('one call may not write one (record, unit) twice', () async {
    final j = _journal(InMemoryJournalStore());
    UnitWriteDraft d(String t) => UnitWriteDraft.content(
        identity: a, unit: body, fields: {'text': t}, observedLive: {});
    await expectLater(j.write([d('x'), d('y')]), throwsArgumentError);
    expect(await j.readAll(), isEmpty);
  });

  test('a write and its projection land together or not at all', () async {
    final store = _FailingStore(failOnProject: 2);
    final j = _journal(store);
    await expectLater(
        j.write([
          UnitWriteDraft.content(
              identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
          UnitWriteDraft.content(
              identity: a,
              unit: title,
              fields: {'title': 't'},
              observedLive: {}),
        ]),
        throwsStateError);
    expect(await j.unsent(), isEmpty);
    expect(await j.readAll(), isEmpty);
  });

  test('absorb admits through the door and is idempotent', () async {
    final alice = _journal(InMemoryJournalStore(), seed: 1);
    final bob = _journal(InMemoryJournalStore(), seed: 2);
    await alice.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    final [sent] = await alice.unsent();
    expect(await bob.absorb(sent.bytes), isA<Appended>());
    expect(await bob.absorb(sent.bytes), isA<AlreadyHeld>(),
        reason: 'a re-delivered frame must not read as a change');
    expect(await _snapshot(bob), await _snapshot(alice));
    expect(await bob.unsent(), isEmpty, reason: 'absorbed writes are not sent');
  });

  test('a refused frame changes nothing', () async {
    final j = _journal(InMemoryJournalStore());
    final r = await j.absorb(Uint8List.fromList('{"v":1}'.codeUnits));
    expect(r, isA<NotAdmitted>());
    expect(await j.readAll(), isEmpty);
  });

  test('C1: devices exchanging writes in any order converge', () async {
    final rng = Random(3);
    final devices = [
      for (var i = 0; i < 3; i++) _journal(InMemoryJournalStore(), seed: i),
    ];
    final ids = [note('a'), note('b')];
    // Each device edits from its own view, so concurrent edits race.
    for (var step = 0; step < 30; step++) {
      final d = devices[rng.nextInt(devices.length)];
      final id = ids[rng.nextInt(ids.length)];
      final rid = noteDoor.resolve(id)!.id;
      final v = await d.read(rid);
      final draft = switch (rng.nextInt(4)) {
        0 => UnitWriteDraft.delete(
            identity: id,
            observedLiveTomb: v?.tomb?.liveIds ?? {},
            sawContent: v?.liveContentIds ?? {}),
        1 => UnitWriteDraft.restore(
            identity: id, observedLiveTomb: v?.tomb?.liveIds ?? {}),
        _ => UnitWriteDraft.content(
            identity: id,
            unit: body,
            fields: {'text': 'v${rng.nextInt(3)}'},
            observedLive: v?.units[body]?.liveIds ?? {}),
      };
      await d.write([draft]);
      // Sometimes share everything one device has sent with one other.
      if (rng.nextBool()) {
        final to = devices[rng.nextInt(devices.length)];
        for (final e in await d.unsent()) {
          await to.absorb(e.bytes);
        }
      }
    }
    // Finally everyone receives everything, each in its own shuffled order.
    final everything = [
      for (final d in devices) ...[for (final e in await d.unsent()) e.bytes],
    ];
    for (final d in devices) {
      for (final b in [...everything]..shuffle(rng)) {
        await d.absorb(b);
      }
    }
    final first = await _snapshot(devices.first);
    for (final d in devices.skip(1)) {
      expect(await _snapshot(d), first);
    }
  });

  test('recompute rebuilds the same projection from the log alone', () async {
    final j = _journal(InMemoryJournalStore());
    final other = _journal(InMemoryJournalStore(), seed: 9);
    await j.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    await other.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'y'}, observedLive: {}),
    ]);
    await j.absorb((await other.unsent()).single.bytes);
    final before = await _snapshot(j);
    await j.recompute();
    expect(await _snapshot(j), before);
    expect(before, contains('shown={"text":"x"} {"text":"y"}'));
  });

  test('unsent and markAcked', () async {
    final j = _journal(InMemoryJournalStore());
    UnitWriteDraft d(Identity id) => UnitWriteDraft.content(
        identity: id, unit: body, fields: {'text': 'x'}, observedLive: {});
    await j.write([d(note('1'))]);
    await j.write([d(note('2')), d(note('3'))]);
    final unsent = await j.unsent();
    expect([for (final e in unsent) e.seq], [1, 2, 3]);
    await j.markAcked(2);
    expect([for (final e in await j.unsent()) e.seq], [3]);
    await j.markAcked(1);
    expect([for (final e in await j.unsent()) e.seq], [3],
        reason: 'never moves backwards');
    await expectLater(j.markAcked(4), throwsArgumentError);
  });

  test('a read overlapping a write never loses the write', () async {
    final j = _journal(InMemoryJournalStore());
    UnitWriteDraft d(String n) => UnitWriteDraft.content(
        identity: note(n), unit: body, fields: {'text': n}, observedLive: {});
    for (var i = 0; i < 20; i++) {
      await j.write([d('seed$i')]);
    }
    final writing = j.write([d('new')]);
    final reading = j.readAll();
    await Future.wait([writing, reading]);
    final [w] = await writing;
    expect(await j.readAll(), hasLength(21));
    expect([for (final e in await j.unsent()) WriteId.ofBytes(e.bytes)],
        contains(w));
  });

  test('a store holding a lock that is not reentrant never deadlocks',
      () async {
    // The shape a cross-tab store takes: one non-reentrant lock, taken inside
    // transaction(). Every journal operation must get through it.
    final store = _LockedStore();
    final j = _journal(store);
    await j.write([
      UnitWriteDraft.content(
          identity: a, unit: body, fields: {'text': 'x'}, observedLive: {}),
    ]);
    await j.absorb((await j.unsent()).single.bytes);
    await j.read(aId);
    await j.readAll();
    await j.recompute();
    await j.markAcked(1);
    expect(store.held, isFalse);
    expect(store.taken, greaterThanOrEqualTo(7));
  });

  test('the queue survives a failed operation', () async {
    final q = isolateLocalQueue();
    await expectLater(q(() async => throw StateError('x')), throwsStateError);
    expect(await q(() async => 1), 1);
  });

  test('a failure nobody awaits still reaches the zone', () async {
    final unhandled = <Object>[];
    final done = Completer<void>();
    // zone-ok: an unhandled async error is only observable through a zone.
    runZonedGuarded(() {
      final q = isolateLocalQueue();
      unawaited(q<void>(() async => throw StateError('dropped')));
      q(() async => done.complete());
    }, (error, _) => unhandled.add(error));
    await done.future;
    await Future<void>.delayed(Duration.zero);
    expect(unhandled, [isA<StateError>()]);
  });
}

/// An in-memory store whose Nth projection write throws, mid-transaction.
final class _FailingStore implements JournalStore {
  _FailingStore({required this.failOnProject});

  final int failOnProject;
  final _inner = InMemoryJournalStore();
  int _projects = 0;

  @override
  Future<T> transaction<T>(Future<T> Function(JournalTransaction txn) body) =>
      _inner.transaction((txn) => body(_Failing(txn, this)));
}

final class _Failing implements JournalTransaction {
  _Failing(this._txn, this._store);

  final JournalTransaction _txn;
  final _FailingStore _store;

  @override
  Future<void> project(RecordId record, WriteId write, Uint8List bytes) {
    if (++_store._projects == _store.failOnProject) {
      throw StateError('disk full');
    }
    return _txn.project(record, write, bytes);
  }

  @override
  Future<int> lastSeq() => _txn.lastSeq();
  @override
  Future<int> ackedSeq() => _txn.ackedSeq();
  @override
  Future<void> setAckedSeq(int seq) => _txn.setAckedSeq(seq);
  @override
  Future<void> append(JournalEntry entry) => _txn.append(entry);
  @override
  Future<List<JournalEntry>> entriesAfter(int seq) => _txn.entriesAfter(seq);
  @override
  Future<bool> holds(WriteId write) => _txn.holds(write);
  @override
  Future<List<Uint8List>> projected(RecordId record) => _txn.projected(record);
  @override
  Future<List<RecordId>> projectedRecords() => _txn.projectedRecords();
  @override
  Future<void> clearProjection() => _txn.clearProjection();
}

/// An in-memory store that takes a lock which is not reentrant, as a web
/// store's navigator.locks is, around every transaction.
final class _LockedStore implements JournalStore {
  final _inner = InMemoryJournalStore();
  final _lock = isolateLocalQueue();
  bool held = false;
  int taken = 0;

  @override
  Future<T> transaction<T>(Future<T> Function(JournalTransaction txn) body) =>
      _lock(() async {
        if (held) throw StateError('lock taken twice');
        held = true;
        taken++;
        try {
          return await _inner.transaction(body);
        } finally {
          held = false;
        }
      });
}
