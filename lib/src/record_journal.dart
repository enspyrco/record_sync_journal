import 'dart:math';
import 'dart:typed_data';

import 'journal_store.dart';
import 'unit_write.dart';
import 'values.dart';
import 'view.dart';

/// The device journal: where a local write is the log.
///
/// - A write and its projection land in one transaction.
/// - The projection is each record's set of admitted write bytes, and a
///   record's value is a function of that set ([RecordView.of]), so there is
///   no merged state to keep right. [recompute] rebuilds it from the log.
/// - Every write, authored here, absorbed or relayed, enters through one
///   [Door].
/// - The store's transaction is the only exclusion. The door is a pure
///   function of bytes, so admitting runs outside any transaction.
/// - No clock is read anywhere.
final class RecordJournal {
  /// A journal over [store], reading identities through [families]. [random]
  /// draws salts.
  ///
  /// The journal takes no lock of its own. When other isolates or tabs share
  /// the store, its [JournalStore.transaction] takes the lock that spans them.
  RecordJournal({
    required JournalStore store,
    required Iterable<IdentityFamily> families,
    Random? random,
  })  : _store = store,
        door = Door(families),
        _random = random ?? Random.secure();

  final JournalStore _store;
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
    return _store.transaction((txn) async {
      for (final w in writes) {
        await _append(txn, w, Provenance.authored);
      }
      return [for (final w in writes) w.id];
    });
  }

  /// Admits [frame], received from a peer that publishes it itself, and when
  /// admitted and new, appends and projects it. Receiving the same bytes
  /// again changes nothing, and the result says so: only [Appended] means the
  /// journal grew. An absorbed write is never sent from here, so a frame
  /// whose publisher can't be relied on to send it on, such as one from an
  /// archive, goes to [relay] instead.
  Future<Absorption> absorb(List<int> frame) =>
      _take(frame, Provenance.received);

  /// As [absorb], for a write this device must pass on because its publisher
  /// may never send it again, as when importing an archive: it is listed in
  /// [unsent] like a write authored here. A write already held keeps the
  /// provenance it arrived with: its publisher sent it then.
  Future<Absorption> relay(List<int> frame) => _take(frame, Provenance.relayed);

  Future<Absorption> _take(List<int> frame, Provenance provenance) async {
    switch (door.admit(frame)) {
      case Refused refused:
        return NotAdmitted(refused);
      case Admitted(:final write):
        final appended =
            await _store.transaction((txn) => _append(txn, write, provenance));
        return appended ? Appended(write) : AlreadyHeld(write);
    }
  }

  /// What is stored for [record], or null only when nothing is. Writes a
  /// newer build made are left out and listed as unread; a stored write that
  /// can't be read for any other reason makes it an [UnreadableRecord], which
  /// the caller decides how to show. Nothing here throws on a stored write,
  /// so a corrupt record can't crash a build that can no longer be patched.
  ///
  /// The transaction only copies bytes; the door reads them after it ends, so
  /// a read never holds writers back while it parses.
  Future<RecordRead?> read(RecordId record) async {
    final bytes = await _store.transaction((txn) => txn.projected(record));
    return bytes.isEmpty ? null : _readRecord(record, bytes);
  }

  /// Every stored record, ordered by id. A record with a corrupt write is an
  /// [UnreadableRecord] rather than a throw, so it can't hide the rest. Bytes
  /// are copied in one transaction and read after it ends.
  Future<List<RecordRead>> readAll() async {
    final byRecord = await _store.transaction((txn) async {
      final ids = [...await txn.projectedRecords()]..sort();
      return [for (final id in ids) (id, await txn.projected(id))];
    });
    // A record listed with nothing projected is not stored, as in [read].
    return [
      for (final (id, bytes) in byRecord)
        if (bytes.isNotEmpty) _readRecord(id, bytes),
    ];
  }

  /// Rebuilds the projection from the log alone. It must equal the projection
  /// the live writes built.
  Future<void> recompute() => _store.transaction((txn) async {
        await txn.clearProjection();
        for (final e in await txn.entriesAfter(0)) {
          final w = _readmit(e.bytes);
          await txn.project(w.record, w.id, w.bytes);
        }
      });

  /// Writes this device sends (authored or relayed) and not yet
  /// acknowledged, oldest first.
  Future<List<JournalEntry>> unsent() => _store.transaction((txn) async => [
        for (final e in await txn.entriesAfter(await txn.ackedSeq()))
          if (e.provenance.isSentFromHere) e,
      ]);

  /// Marks every entry up to and including [seq] acknowledged: a watermark,
  /// so pass the highest seq below which the transport has delivered every
  /// entry, never one past an entry still unsent. Never moves backwards;
  /// throws an [ArgumentError] past the last entry.
  Future<void> markAcked(int seq) => _store.transaction((txn) async {
        if (seq <= await txn.ackedSeq()) return;
        if (seq > await txn.lastSeq()) {
          throw ArgumentError.value(seq, 'seq', 'beyond the last entry');
        }
        await txn.setAckedSeq(seq);
      });

  /// Appends and projects [w] unless it is already held; true when it was new.
  Future<bool> _append(
      JournalTransaction txn, UnitWrite w, Provenance provenance) async {
    if (await txn.holds(w.id)) return false;
    await txn.append(
        JournalEntry(await txn.lastSeq() + 1, w.bytes, provenance: provenance));
    await txn.project(w.record, w.id, w.bytes);
    return true;
  }

  /// [record]'s stored [bytes], which are not empty, read through the door.
  /// When several writes are faulty, the one with the smallest id names the
  /// fault, so every device reports alike.
  RecordRead _readRecord(RecordId record, List<Uint8List> bytes) {
    final writes = <UnitWrite>[];
    final unread = <UnreadWrite>[];
    (WriteId, StoredWriteFault)? broken;
    void fault(WriteId id, StoredWriteFault f) {
      if (broken == null || id.compareTo(broken!.$1) < 0) broken = (id, f);
    }

    for (final b in bytes) {
      switch (door.admit(b)) {
        case Admitted(:final write) when write.record != record:
          fault(write.id, MisfiledStoredWrite(write.record));
        case Admitted(:final write):
          writes.add(write);
        case Refused(record: final named?, :final id) when named != record:
          fault(id, MisfiledStoredWrite(named));
        case Refused refused:
          switch (UnreadWrite.parse(refused)) {
            case final UnreadWrite u:
              unread.add(u);
            case null:
              fault(refused.id, RefusedStoredWrite(refused.reason));
          }
      }
    }
    if (broken case (_, final f)?) return UnreadableRecord(record, f);
    if (writes.isEmpty) return UnreadRecord(record, unread);
    return Readable(RecordView.of(writes, unread: unread));
  }

  /// For [recompute], which stays strict: every stored write must be read, so
  /// an older build can never rebuild a newer build's writes away.
  UnitWrite _readmit(List<int> bytes) => switch (door.admit(bytes)) {
        Admitted(:final write) => write,
        Refused(:final reason, :final id) =>
          throw StateError('stored write $id no longer admitted: $reason'),
      };
}

/// What [RecordJournal.absorb] or [RecordJournal.relay] did with a frame.
sealed class Absorption {
  const Absorption();
}

/// Admitted and new: the journal grew, so views over its record changed.
final class Appended extends Absorption {
  const Appended(this.write);
  final UnitWrite write;
}

/// Admitted, and already held: nothing changed.
final class AlreadyHeld extends Absorption {
  const AlreadyHeld(this.write);
  final UnitWrite write;
}

/// Refused by the door: nothing changed.
final class NotAdmitted extends Absorption {
  const NotAdmitted(this.refused);
  final Refused refused;
}
