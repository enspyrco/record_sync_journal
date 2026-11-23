import 'dart:math';

import 'journal_store.dart';
import 'serializer.dart';
import 'unit_write.dart';
import 'values.dart';
import 'view.dart';

/// The device journal: where a local write is the log.
///
/// - A write and its projection land in one transaction.
/// - The projection is each record's set of admitted write bytes, and a
///   record's value is a function of that set ([RecordView.of]), so there is
///   no merged state to keep right. [recompute] rebuilds it from the log.
/// - Every write, authored here or absorbed, enters through one [Door].
/// - No clock is read anywhere.
final class RecordJournal {
  /// A journal over [store], reading identities through [families].
  ///
  /// [serialize] orders this journal's writes (write, absorb, recompute,
  /// markAcked); pass a lock that also spans other isolates or tabs when the
  /// store is shared with them. Reads take no lock: the store's transactions
  /// isolate them. [random] draws
  /// salts.
  RecordJournal({
    required JournalStore store,
    required Iterable<IdentityFamily> families,
    Serializer? serialize,
    Random? random,
  })  : _store = store,
        door = Door(families),
        _serialize = serialize ?? isolateLocalQueue(),
        _random = random ?? Random.secure();

  final JournalStore _store;
  final Serializer _serialize;
  final Random _random;

  /// The door every write enters through.
  final Door door;

  /// Salts, encodes and admits [drafts], then appends and projects them in one
  /// transaction. Returns their ids in order.
  ///
  /// Throws an [ArgumentError], storing nothing, when the door refuses any
  /// draft or two drafts write one (record, unit).
  Future<List<WriteId>> write(List<UnitWriteDraft> drafts) async {
    final writes = <UnitWrite>[];
    final targets = <(RecordId, UnitName)>{};
    for (final d in drafts) {
      final bytes = d.encode(d.salted ? Salt.random(_random) : null);
      switch (door.admit(bytes)) {
        case Admitted(:final write):
          if (!targets.add((write.record, write.unit))) {
            throw ArgumentError.value(write.unit, 'drafts',
                'written twice for ${write.record} in one call');
          }
          writes.add(write);
        case Refused(:final reason):
          throw ArgumentError.value(d.identity, 'drafts', 'refused: $reason');
      }
    }
    return _serialize(() => _store.transaction((txn) async {
          for (final w in writes) {
            await _append(txn, w, authoredHere: true);
          }
          return [for (final w in writes) w.id];
        }));
  }

  /// Admits [frame] through the door and, when admitted and new, appends and
  /// projects it. Receiving the same bytes again changes nothing.
  Future<Admission> absorb(List<int> frame) {
    final admission = door.admit(frame);
    if (admission case Admitted(:final write)) {
      return _serialize(() => _store.transaction((txn) async {
            await _append(txn, write, authoredHere: false);
            return admission;
          }));
    }
    return Future.value(admission);
  }

  /// [record]'s view, or null when no write names it.
  Future<RecordView?> read(RecordId record) => _store.transaction((txn) async {
        final bytes = await txn.projected(record);
        return bytes.isEmpty ? null : RecordView.of(bytes.map(_readmit));
      });

  /// Every record's view, ordered by id.
  Future<List<RecordView>> readAll() => _store.transaction((txn) async {
        final ids = [...await txn.projectedRecords()]..sort();
        return [
          for (final id in ids)
            RecordView.of((await txn.projected(id)).map(_readmit)),
        ];
      });

  /// Rebuilds the projection from the log alone. It must equal the projection
  /// the live writes built.
  Future<void> recompute() => _serialize(() => _store.transaction((txn) async {
        await txn.clearProjection();
        for (final e in await txn.entriesAfter(0)) {
          final w = _readmit(e.bytes);
          await txn.project(w.record, w.id, w.bytes);
        }
      }));

  /// Writes authored here and not yet acknowledged, oldest first.
  Future<List<JournalEntry>> unsent() => _store.transaction((txn) async => [
        for (final e in await txn.entriesAfter(await txn.ackedSeq()))
          if (e.authoredHere) e,
      ]);

  /// Marks every entry up to and including [seq] acknowledged: a watermark,
  /// so pass the highest seq below which the transport has delivered every
  /// entry, never one past an entry still unsent. Never moves backwards;
  /// throws an [ArgumentError] past the last entry.
  Future<void> markAcked(int seq) =>
      _serialize(() => _store.transaction((txn) async {
            if (seq <= await txn.ackedSeq()) return;
            if (seq > await txn.lastSeq()) {
              throw ArgumentError.value(seq, 'seq', 'beyond the last entry');
            }
            await txn.setAckedSeq(seq);
          }));

  Future<void> _append(JournalTransaction txn, UnitWrite w,
      {required bool authoredHere}) async {
    if (await txn.holds(w.id)) return;
    await txn.append(JournalEntry(await txn.lastSeq() + 1, w.bytes,
        authoredHere: authoredHere));
    await txn.project(w.record, w.id, w.bytes);
  }

  /// Bytes from the store were admitted once by this door; a refusal now means
  /// the families changed under the store, which no view can paper over.
  UnitWrite _readmit(List<int> bytes) => switch (door.admit(bytes)) {
        Admitted(:final write) => write,
        Refused(:final reason, :final id) =>
          throw StateError('stored write $id no longer admitted: $reason'),
      };
}
