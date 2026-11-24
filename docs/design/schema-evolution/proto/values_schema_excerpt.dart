
  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The units a record type declares: each unit's name and the fields written
/// whole under it. Every record also has the reserved [UnitName.tomb].
final class RecordSchema {
  RecordSchema._(this.type, this.units, this.writeOnce);

  /// A record type. Throws an [ArgumentError] when [units] declares the
  /// reserved [UnitName.tomb], which every record has and the door reads by
  /// its own rule, or when [writeOnce] names a unit [units] does not declare.
  factory RecordSchema({
    required RecordType type,
    required Map<UnitName, Set<FieldName>> units,
    Set<UnitName> writeOnce = const {},
  }) {
    if (units.keys.any((u) => u.isTomb)) {
      throw ArgumentError.value(type, 'units', '_tomb is reserved');
    }
    for (final n in writeOnce) {
      if (!units.containsKey(n)) {
        throw ArgumentError.value(n, 'writeOnce', 'not a unit of $type');
      }
    }
    return RecordSchema._(
        type,
        Map.unmodifiable({
          for (final MapEntry(:key, :value) in units.entries)
            key: Set<FieldName>.unmodifiable(value),
        }),
        Set.unmodifiable(writeOnce));
  }

  final RecordType type;

  /// Unit → the fields written whole under it. [UnitName.tomb] is not listed.
  final Map<UnitName, Set<FieldName>> units;

  /// Units written once, at birth. The door refuses a write to one of these
  /// that names any write it saw, so such a write can only be a birth, and a
  /// unit two births race on stays that way: no write can settle it.
  final Set<UnitName> writeOnce;
}

/// What an [IdentityFamily] reads from one identity: the family's own key for
/// the record, and the record's type.
typedef FamilyRecord = ({RecordKey key, RecordSchema schema});

/// What a [Door] reads from an identity: the record's id and type.
typedef ResolvedIdentity = ({RecordId id, RecordSchema schema});

/// Reads one family of identities: derives each one's key and type.
///
/// The app supplies these. Two different identities in one family must never
/// derive the same key; [HashedIdentityFamily] holds to that up to SHA-256.
/// Keys from different families never meet, because a [RecordId] carries its
/// family.
abstract interface class IdentityFamily {
