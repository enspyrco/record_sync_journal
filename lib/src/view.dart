import 'values.dart';
import 'unit_write.dart';

/// One unit's value over its admitted writes (DESIGN §1.2):
///
/// ```
/// dead  = ⋃ kills       live  = writes ∖ dead
/// shown = the distinct canonical field values of live
/// ```
final class UnitState {
  UnitState._(this.live, this.shown);

  /// The state of one (record, unit) over [writes], all of which must be of
  /// that record and unit. Order and duplicates make no difference.
  factory UnitState.of(Iterable<UnitWrite> writes) {
    final all = {for (final w in writes) w.id: w};
    final dead = {for (final w in all.values) ...w.kills};
    final live = [
      for (final w in all.values)
        if (!dead.contains(w.id)) w,
    ]..sort((a, b) => a.id.compareTo(b.id));
    final values = {for (final w in live) w.fields}.toList()
      ..sort((a, b) => a.text.compareTo(b.text));
    return UnitState._(Set.unmodifiable(live), Set.unmodifiable(values));
  }

  /// The writes no admitted write of this unit kills.
  final Set<UnitWrite> live;

  /// The distinct live values: a set, never one pick. It iterates in order of
  /// canonical text so every device lays values out alike; the order means
  /// nothing.
  final Set<CanonicalObject> shown;

  /// More than one distinct live value: a race, drawn with all its values.
  bool get contested => shown.length > 1;

  /// The ids of [live]: what an author who saw this unit now passes as kills.
  Set<WriteId> get liveIds => {for (final w in live) w.id};
}

/// One record over its admitted writes: every unit's state, and whether the
/// record is drawn, hidden or a ghost (DESIGN §3.6.5, D1).
sealed class RecordView {
  RecordView._(_Args a)
      : id = a.$1,
        identity = a.$2,
        schema = a.$3,
        units = a.$4,
        unread = a.$5;

  /// The view of [writes], all of one record, with [unread] the record's
  /// stored writes this build left out. An [UnreadWrite] doesn't say which
  /// record it belongs to, so the caller must pair them. Throws an
  /// [ArgumentError] when [writes] is empty or spans records. Order and
  /// duplicates make no difference.
  factory RecordView.of(Iterable<UnitWrite> writes,
      {Iterable<UnreadWrite> unread = const []}) {
    final byUnit = <UnitName, List<UnitWrite>>{};
    UnitWrite? first;
    for (final w in writes) {
      if (first != null && w.record != first.record) {
        throw ArgumentError.value(w.record, 'writes', 'more than one record');
      }
      // Identity and schema are taken from the write with the smallest id, so
      // the view does not depend on arrival order even under a family that
      // breaks its contract and derives one id from two identities.
      if (first == null || w.id.compareTo(first.id) < 0) first = w;
      (byUnit[w.unit] ??= []).add(w);
    }
    if (first == null) throw ArgumentError.value(writes, 'writes', 'empty');

    final units = {
      for (final MapEntry(key: u, value: ws) in byUnit.entries)
        u: UnitState.of(ws),
    };
    final tomb = units[UnitName.tomb];
    final deleted = tomb?.shown
            .map((f) => f.json.boolean(FieldName.deleted.value))
            .toSet() ??
        const <bool>{};

    final args = (
      first.record,
      first.identity,
      first.schema,
      Map<UnitName, UnitState>.unmodifiable(units),
      Set<UnreadWrite>.unmodifiable(unread),
    );
    if (!deleted.contains(true)) return DrawnRecord._(args);

    final witnessed = {
      for (final w in tomb!.live)
        if (w is DeleteWrite) ...w.saw,
    };
    final unseen = {
      for (final MapEntry(key: u, value: s) in units.entries)
        if (!u.isTomb)
          for (final w in s.live)
            if (!witnessed.contains(w.id)) w.id,
    };
    final tombContested = deleted.contains(false);
    if (unseen.isEmpty && !tombContested) return HiddenRecord._(args);
    return GhostRecord._(args, Set.unmodifiable(unseen), tombContested);
  }

  final RecordId id;
  final Identity identity;
  final RecordSchema schema;

  /// Each unit that has any admitted write, `_tomb` included.
  final Map<UnitName, UnitState> units;

  /// Stored writes of this record that a newer build wrote and this one can't
  /// read. They are in no unit, so no `kills` or `saw` computed here names
  /// them. Non-empty means this view is partial.
  final Set<UnreadWrite> unread;

  /// `_tomb`'s state, or null when the record has never been deleted or
  /// restored.
  UnitState? get tomb => units[UnitName.tomb];

  /// The units in a race: live writes with more than one distinct value, on a
  /// unit a write can settle. A write-once unit with several values is left
  /// out, because no write may ever name them; its [UnitState.shown] holds
  /// them all for a fold to read.
  Set<UnitName> get contestedUnits => {
        for (final MapEntry(:key, :value) in units.entries)
          if (value.contested && !schema.writeOnce.contains(key)) key,
      };

  /// Every live write on the record's own units: what a delete computed now
  /// passes as `saw`.
  Set<WriteId> get liveContentIds => {
        for (final MapEntry(:key, :value) in units.entries)
          if (!key.isTomb) ...value.liveIds,
      };
}

/// Not deleted: no `_tomb` write, or `_tomb` is false.
final class DrawnRecord extends RecordView {
  DrawnRecord._(super.a) : super._();
}

/// Deleted, and the live deletes together saw every live content write.
final class HiddenRecord extends RecordView {
  HiddenRecord._(super.a) : super._();
}

/// Deleted, with a question to list: content no live delete saw, or a `_tomb`
/// that is itself contested. Restore or Delete settles it.
final class GhostRecord extends RecordView {
  GhostRecord._(super.a, this.unseen, this.tombContested) : super._();

  /// Live content writes no live delete names in its `saw`.
  final Set<WriteId> unseen;

  /// Whether `_tomb` shows both deleted and restored.
  final bool tombContested;
}

typedef _Args = (
  RecordId,
  Identity,
  RecordSchema,
  Map<UnitName, UnitState>,
  Set<UnreadWrite>,
);

/// A stored write this build can't read, because a newer build wrote it.
///
/// It keeps its write id to itself: [UnitWriteDraft] takes [WriteId]s, so a
/// write nobody here read can never be named in a `kills` or `saw`.
final class UnreadWrite {
  UnreadWrite._(this._id, this.reason);

  /// The write [refused] names, or null unless a newer build could have
  /// written it ([Refusal.isNewerSchema]).
  static UnreadWrite? parse(Refused refused) => refused.reason.isNewerSchema
      ? UnreadWrite._(refused.id, refused.reason)
      : null;

  final WriteId _id;

  /// Which part of the write this build doesn't know.
  final Refusal reason;

  @override
  bool operator ==(Object other) => other is UnreadWrite && other._id == _id;

  @override
  int get hashCode => _id.hashCode;

  @override
  String toString() => 'UnreadWrite($reason)';
}

/// What reading one stored record found.
sealed class RecordRead {
  const RecordRead();

  RecordId get id;
}

/// At least one stored write was read. [RecordView.unread] holds the rest.
final class Readable extends RecordRead {
  const Readable(this.view);
  final RecordView view;

  @override
  RecordId get id => view.id;
}

/// The record is stored, and every write of it was written by a newer build.
/// It is not absent: an editor must not create it again.
final class UnreadRecord extends RecordRead {
  UnreadRecord(this.id, Iterable<UnreadWrite> unread)
      : unread = Set.unmodifiable(unread);

  @override
  final RecordId id;
  final Set<UnreadWrite> unread;
}

/// A stored write of the record can't be part of its view, for a reason no
/// newer build can cause: the freeze was broken or the store is corrupt.
final class UnreadableRecord extends RecordRead {
  const UnreadableRecord(this.id, this.fault);

  @override
  final RecordId id;
  final StoredWriteFault fault;
}

/// What is wrong with a stored write that makes its record unreadable.
sealed class StoredWriteFault {
  const StoredWriteFault();
}

/// The door refuses the write for a reason that isn't
/// [Refusal.isNewerSchema].
final class RefusedStoredWrite extends StoredWriteFault {
  const RefusedStoredWrite(this.reason);
  final Refusal reason;

  @override
  String toString() => 'refused: $reason';
}

/// The door admits the write, but it names another record than the one it is
/// stored under.
final class MisfiledStoredWrite extends StoredWriteFault {
  const MisfiledStoredWrite(this.namedRecord);
  final RecordId namedRecord;

  @override
  String toString() => 'filed here but names $namedRecord';
}
