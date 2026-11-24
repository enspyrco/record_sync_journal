import 'dart:typed_data';

import 'serializer.dart';
import 'values.dart';

/// One appended write: its place in the log, its bytes, and whether this
/// device authored it (and so must send it) or absorbed it from elsewhere.
final class JournalEntry {
  JournalEntry(this.seq, List<int> bytes, {required this.authoredHere})
      : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final int seq;
  final Uint8List bytes;
  final bool authoredHere;
}

/// Where a journal keeps its log and projection. Everything happens inside a
/// [transaction]: it lands whole or not at all, and is isolated, so no
/// transaction ever commits over changes another one committed meanwhile.
///
/// The package ships [InMemoryJournalStore]; an app writes one over its own
/// database.
abstract interface class JournalStore {
  /// Runs [body] in one transaction. If [body] throws, nothing it did lands,
  /// and the error is rethrown. A store may run [body] more than once for one
  /// call (sembast on the web re-runs it when another tab committed first) and
  /// keep only the last run, so every body the journal passes acts only
  /// through `txn`: salts are drawn and bytes encoded before the transaction. This is the journal's only exclusion: take
  /// here whatever lock spans the isolates or tabs sharing the store, outside
  /// the database's own transaction. [body] never opens a second transaction
  /// on the same store, so a lock that is not reentrant is fine.
  Future<T> transaction<T>(Future<T> Function(JournalTransaction txn) body);
}

/// The operations a journal performs inside one transaction.
///
/// Two tables: the log (every admitted write, in append order, plus the acked
/// position) and the projection (each record's admitted write bytes). The
/// journal is the projection's only writer.
abstract interface class JournalTransaction {
  /// The seq of the last appended entry; 0 before any.
  Future<int> lastSeq();

  /// Every entry up to this seq is acknowledged; 0 before any.
  Future<int> ackedSeq();

  Future<void> setAckedSeq(int seq);

  /// Appends [entry]; its seq is one past [lastSeq].
  Future<void> append(JournalEntry entry);

  /// Entries with seq greater than [seq], in seq order.
  Future<List<JournalEntry>> entriesAfter(int seq);

  /// Whether the projection holds [write].
  Future<bool> holds(WriteId write);

  /// Adds [write]'s [bytes] to [record]'s projection.
  Future<void> project(RecordId record, WriteId write, Uint8List bytes);

  /// [record]'s projected write bytes, in no particular order.
  Future<List<Uint8List>> projected(RecordId record);

  /// Every record with a projected write.
  Future<List<RecordId>> projectedRecords();

  /// Empties the projection, leaving the log.
  Future<void> clearProjection();
}

/// A [JournalStore] in memory. Transactions run one at a time, each on a copy
/// that replaces the store's state only when it completes, so none can start
/// from a state another is about to replace.
final class InMemoryJournalStore implements JournalStore {
  _MemoryState _state = _MemoryState();
  final Serializer _oneAtATime = isolateLocalQueue();

  @override
  Future<T> transaction<T>(Future<T> Function(JournalTransaction txn) body) =>
      _oneAtATime(() async {
        final staged = _state.copy();
        final result = await body(_MemoryTransaction(staged));
        _state = staged;
        return result;
      });
}

final class _MemoryState {
  _MemoryState();

  int acked = 0;
  final List<JournalEntry> log = [];
  final Map<RecordId, Map<WriteId, Uint8List>> projection = {};

  _MemoryState copy() => _MemoryState()
    ..acked = acked
    ..log.addAll(log)
    ..projection.addAll({
      for (final MapEntry(:key, :value) in projection.entries) key: {...value},
    });
}

final class _MemoryTransaction implements JournalTransaction {
  _MemoryTransaction(this._s);

  final _MemoryState _s;

  @override
  Future<int> lastSeq() async => _s.log.isEmpty ? 0 : _s.log.last.seq;

  @override
  Future<int> ackedSeq() async => _s.acked;

  @override
  Future<void> setAckedSeq(int seq) async => _s.acked = seq;

  @override
  Future<void> append(JournalEntry entry) async => _s.log.add(entry);

  @override
  Future<List<JournalEntry>> entriesAfter(int seq) async => [
        for (final e in _s.log)
          if (e.seq > seq) e
      ];

  @override
  Future<bool> holds(WriteId write) async =>
      _s.projection.values.any((ws) => ws.containsKey(write));

  @override
  Future<void> project(RecordId record, WriteId write, Uint8List bytes) async =>
      (_s.projection[record] ??= {})[write] = bytes;

  @override
  Future<List<Uint8List>> projected(RecordId record) async =>
      [...?_s.projection[record]?.values];

  @override
  Future<List<RecordId>> projectedRecords() async => [..._s.projection.keys];

  @override
  Future<void> clearProjection() async => _s.projection.clear();
}
