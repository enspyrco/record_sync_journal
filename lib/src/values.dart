import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:crypto/crypto.dart';

import 'canonical_json.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex32 = RegExp(r'^[0-9a-f]{32}$');

String _hexOf(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// A unit write's id: the SHA-256 of the exact bytes received, as 64 lowercase
/// hex digits.
final class WriteId implements Comparable<WriteId> {
  const WriteId._(this.hex);

  /// The id of [bytes], hashed before anything decodes them.
  factory WriteId.ofBytes(List<int> bytes) =>
      WriteId._(sha256.convert(bytes).toString());

  /// Reads an id back from its hex form; null unless it is 64 lowercase hex.
  static WriteId? parse(String hex) =>
      _hex64.hasMatch(hex) ? WriteId._(hex) : null;

  final String hex;

  @override
  int compareTo(WriteId other) => hex.compareTo(other.hex);

  @override
  bool operator ==(Object other) => other is WriteId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// 128 random bits on a write, so that naming its id is evidence of having held
/// its bytes (DESIGN §1.2, C12).
final class Salt {
  const Salt._(this.hex);

  /// A fresh salt drawn from [random], [Random.secure] by default.
  factory Salt.random([Random? random]) {
    final r = random ?? Random.secure();
    return Salt._(_hexOf([for (var i = 0; i < 16; i++) r.nextInt(256)]));
  }

  /// Reads a salt back; null unless it is 32 lowercase hex.
  static Salt? parse(String hex) => _hex32.hasMatch(hex) ? Salt._(hex) : null;

  final String hex;

  @override
  bool operator ==(Object other) => other is Salt && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// Whether [text] can name something: non-empty, with no lone surrogate, so
/// it has a canonical form a store can key on.
bool _isNameText(String text) =>
    text.isNotEmpty && canonicalJsonOrNull(text) != null;

/// The name of an identity family: the value of an identity's `family` field,
/// which selects the [IdentityFamily] that reads it.
final class FamilyName implements Comparable<FamilyName> {
  const FamilyName._(this.value);

  /// A family name; throws an [ArgumentError] when [parse] would return null.
  factory FamilyName.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(value, 'value', 'not a family name'));

  /// A family name, or null when [value] is empty or holds a lone surrogate.
  static FamilyName? parse(String value) =>
      _isNameText(value) ? FamilyName._(value) : null;

  final String value;

  @override
  int compareTo(FamilyName other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is FamilyName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A family's own key for one record. Keys from different families never
/// meet, because a [RecordId] pairs the key with its [FamilyName].
final class RecordKey implements Comparable<RecordKey> {
  const RecordKey._(this.value);

  /// A record key; throws an [ArgumentError] when [parse] would return null.
  factory RecordKey.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(value, 'value', 'not a record key'));

  /// A record key, or null when [value] is empty or holds a lone surrogate.
  static RecordKey? parse(String value) =>
      _isNameText(value) ? RecordKey._(value) : null;

  /// A UUIDv8 (RFC 9562) of SHA-256 over [bytes]: the hash's first 16 bytes
  /// with the version and variant bits set.
  factory RecordKey.uuidV8OfSha256(List<int> bytes) {
    final h = Uint8List.fromList(sha256.convert(bytes).bytes.sublist(0, 16));
    h[6] = (h[6] & 0x0f) | 0x80;
    h[8] = (h[8] & 0x3f) | 0x80;
    final hex = _hexOf(h);
    return RecordKey._('${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}');
  }

  final String value;

  @override
  int compareTo(RecordKey other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is RecordKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The name of a record type, as the app knows it.
final class RecordType {
  const RecordType._(this.value);

  /// A record type; throws an [ArgumentError] when [parse] would return null.
  factory RecordType.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(value, 'value', 'not a record type'));

  /// A record type, or null when [value] is empty or holds a lone surrogate.
  static RecordType? parse(String value) =>
      _isNameText(value) ? RecordType._(value) : null;

  final String value;

  @override
  bool operator ==(Object other) => other is RecordType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A record's id: the family that derived it and that family's key for it.
///
/// Two families can never derive the same id, whatever keys they choose; a
/// family need only keep its own keys distinct. The id never travels on the
/// wire.
final class RecordId implements Comparable<RecordId> {
  const RecordId(this.family, this.key);

  /// Reads back an id a store saved as [storageKey]; null when [text] is not
  /// exactly one.
  static RecordId? parseStorageKey(String text) {
    if (!nestsWithin(text.codeUnits, 1)) return null;
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed case [String family, String key]
        when canonicalJsonOrNull([family, key]) == text) {
      final (f, k) = (FamilyName.parse(family), RecordKey.parse(key));
      return f == null || k == null ? null : RecordId(f, k);
    }
    return null;
  }

  /// The family that derived this id.
  final FamilyName family;

  /// The family's own key for the record.
  final RecordKey key;

  /// One string per id, for a store's key column: the canonical JSON of
  /// `[family, key]`, so no two ids share one.
  String get storageKey => canonicalJson([family.value, key.value]);

  @override
  int compareTo(RecordId other) {
    final byFamily = family.compareTo(other.family);
    return byFamily != 0 ? byFamily : key.compareTo(other.key);
  }

  @override
  bool operator ==(Object other) =>
      other is RecordId && other.family == family && other.key == key;

  @override
  int get hashCode => Object.hash(family, key);

  /// The [storageKey]: one text per id, so two ids never print alike.
  @override
  String toString() => storageKey;
}

/// The name of a merge unit: a group of fields always written whole.
///
/// A leading underscore is reserved; the one reserved unit is [tomb].
final class UnitName implements Comparable<UnitName> {
  const UnitName._(this.value);

  /// An app unit; throws an [ArgumentError] when [value] is empty or reserved.
  factory UnitName.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(
          value, 'value', 'a unit name is non-empty and has no leading "_"'));

  /// Reads an app unit name; null when empty or reserved.
  static UnitName? parse(String value) =>
      value.isEmpty || value.startsWith('_') ? null : UnitName._(value);

  /// The unit holding whether the record is deleted.
  static const tomb = UnitName._('_tomb');

  final String value;

  bool get isTomb => identical(this, tomb) || value == tomb.value;

  @override
  int compareTo(UnitName other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is UnitName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A value in canonical form: one of the values [canonicalJson] accepts, held
/// with its canonical text. Two are equal exactly when their texts are.
final class CanonicalObject {
  CanonicalObject._(this.json, this.text);

  /// Checks [fields] once; throws an [ArgumentError] when any value is outside
  /// canonical JSON (a double, a lone surrogate, an integer past 2^53 − 1).
  factory CanonicalObject.of(Map<String, Object?> fields) =>
      parse(fields) ??
      (throw ArgumentError.value(fields, 'fields', 'outside canonical JSON'));

  /// [fields] in canonical form, or null when outside canonical JSON.
  static CanonicalObject? parse(Map<String, Object?> fields) {
    final text = canonicalJsonOrNull(fields);
    if (text == null) return null;
    // Re-decoded from its own text, so the held value is a copy no caller can
    // mutate, frozen all the way down.
    return CanonicalObject._(JsonObject.decode(text).deepFrozen(), text);
  }

  /// The value, read-only all the way down.
  final JsonObject json;

  /// The canonical text.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CanonicalObject && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

/// What a record is, as the wire names it: `{family, …family fields}`. The
/// record's id is derived from this by the app's [IdentityFamily].
final class Identity {
  Identity._(this.family, this.fields);

  /// An identity in [family]. Throws an [ArgumentError] when [fields] names
  /// `family` itself or holds a value outside canonical JSON.
  factory Identity.of(FamilyName family, Map<String, Object?> fields) {
    if (fields.containsKey(familyKey)) {
      throw ArgumentError.value(
          fields, 'fields', '"family" is set by [family]');
    }
    return Identity._(family, CanonicalObject.of(fields));
  }

  /// Reads the wire's identity object; null unless it holds a string `family`
  /// and is canonical.
  static Identity? parse(JsonObject wire) {
    final familyWire = wire.raw(familyKey);
    final family = familyWire is String ? FamilyName.parse(familyWire) : null;
    final fields =
        CanonicalObject.parse(wire.without({familyKey}).asUncheckedMap());
    return family == null || fields == null ? null : Identity._(family, fields);
  }

  static const familyKey = 'family';

  /// The family, which selects the [IdentityFamily] that reads it.
  final FamilyName family;

  /// Every identity field but `family`.
  final CanonicalObject fields;

  Map<String, Object?> toJson() =>
      {...fields.json.asUncheckedMap(), familyKey: family.value};

  /// The identity's canonical text, `family` included.
  String get canonicalText => canonicalJson(toJson());

  @override
  bool operator ==(Object other) =>
      other is Identity && other.family == family && other.fields == fields;

  @override
  int get hashCode => Object.hash(family, fields);

  @override
  String toString() => canonicalText;
}

/// The name of a field inside a unit. A leading underscore is reserved.
final class FieldName implements Comparable<FieldName> {
  const FieldName._(this.value);

  /// A field name; throws an [ArgumentError] when empty or reserved.
  factory FieldName.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(
          value, 'value', 'a field name is non-empty and has no leading "_"'));

  /// A field name, or null when empty or reserved.
  static FieldName? parse(String value) =>
      value.isEmpty || value.startsWith('_') ? null : FieldName._(value);

  /// The one field of [UnitName.tomb]: whether the record is deleted.
  static const deleted = FieldName._('_deleted');

  final String value;

  @override
  int compareTo(FieldName other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is FieldName && other.value == value;

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
  /// The identity `family` that selects this family.
  FamilyName get name;

  /// Whether a write in this family may be unsalted: a birth whose bytes any
  /// device would mint identically, so two devices make one write.
  bool get allowsDeterministicBirth;

  /// The record [identity] names, or null when it is not a valid member of
  /// this family. [identity]'s `family` is already [name].
  FamilyRecord? resolve(Identity identity);
}

/// A family whose key is a UUIDv8 of SHA-256 over the identity's canonical
/// text, and whose identity holds exactly [fields], each a non-empty string or
/// an integer.
final class HashedIdentityFamily implements IdentityFamily {
  /// Throws an [ArgumentError] when [fields] names `family`, which every
  /// identity already carries.
  HashedIdentityFamily({
    required this.name,
    required this.schema,
    required Set<FieldName> fields,
    this.allowsDeterministicBirth = false,
  }) : fields = Set.unmodifiable(fields) {
    if (fields.any((f) => f.value == Identity.familyKey)) {
      throw ArgumentError.value(
          fields, 'fields', '"family" is every identity\'s');
    }
  }

  @override
  final FamilyName name;

  final RecordSchema schema;

  /// The identity's fields, `family` excepted.
  final Set<FieldName> fields;

  @override
  final bool allowsDeterministicBirth;

  @override
  FamilyRecord? resolve(Identity identity) {
    final keys = identity.fields.json.keys.toSet();
    final names = {for (final f in fields) f.value};
    if (keys.length != names.length || !keys.containsAll(names)) return null;
    for (final k in keys) {
      switch (identity.fields.json.raw(k)) {
        case String s when s.isNotEmpty:
        case int _:
          break;
        default:
          return null;
      }
    }
    return (
      key: RecordKey.uuidV8OfSha256(utf8.encode(identity.canonicalText)),
      schema: schema
    );
  }
}
