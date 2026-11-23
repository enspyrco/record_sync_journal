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

/// A record's id. It is derived from the record's [Identity] by the app's
/// identity family and never travels on the wire.
final class RecordId implements Comparable<RecordId> {
  const RecordId._(this.value);

  /// A record id; throws an [ArgumentError] when [value] is empty.
  factory RecordId.of(String value) =>
      parse(value) ??
      (throw ArgumentError.value(value, 'value', 'a record id is non-empty'));

  /// Reads a record id back, as a store does; null when [value] is empty.
  static RecordId? parse(String value) =>
      value.isEmpty ? null : RecordId._(value);

  /// A UUIDv8 (RFC 9562) of SHA-256 over [bytes]: the hash's first 16 bytes
  /// with the version and variant bits set.
  factory RecordId.uuidV8OfSha256(List<int> bytes) {
    final h = Uint8List.fromList(sha256.convert(bytes).bytes.sublist(0, 16));
    h[6] = (h[6] & 0x0f) | 0x80;
    h[8] = (h[8] & 0x3f) | 0x80;
    final hex = _hexOf(h);
    return RecordId._('${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}');
  }

  final String value;

  @override
  int compareTo(RecordId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is RecordId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
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

  /// The one field of [tomb].
  static const deletedField = '_deleted';

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
  factory Identity.of(String family, Map<String, Object?> fields) {
    if (fields.containsKey(familyKey)) {
      throw ArgumentError.value(
          fields, 'fields', '"family" is set by [family]');
    }
    return Identity._(family, CanonicalObject.of(fields));
  }

  /// Reads the wire's identity object; null unless it holds a string `family`
  /// and is canonical.
  static Identity? parse(JsonObject wire) {
    final family = wire.raw(familyKey);
    if (family is! String) return null;
    final fields =
        CanonicalObject.parse(wire.without({familyKey}).asUncheckedMap());
    return fields == null ? null : Identity._(family, fields);
  }

  static const familyKey = 'family';

  /// The family's wire name, which selects the [IdentityFamily] that reads it.
  final String family;

  /// Every identity field but `family`.
  final CanonicalObject fields;

  Map<String, Object?> toJson() =>
      {...fields.json.asUncheckedMap(), familyKey: family};

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

/// The units a record type declares: each unit's name and the fields written
/// whole under it. Every record also has the reserved [UnitName.tomb].
final class RecordSchema {
  RecordSchema._(this.type, this.units, this.writeOnce);

  /// A record type. Throws an [ArgumentError] when a unit or field name is
  /// reserved (a leading `_`) or empty, or when [writeOnce] names an undeclared
  /// unit.
  factory RecordSchema({
    required String type,
    required Map<String, List<String>> units,
    Set<String> writeOnce = const {},
  }) {
    final declared = <UnitName, Set<String>>{};
    for (final MapEntry(key: name, value: fields) in units.entries) {
      for (final f in fields) {
        if (f.isEmpty || f.startsWith('_')) {
          throw ArgumentError.value(f, 'field', 'non-empty, no leading "_"');
        }
      }
      declared[UnitName.of(name)] = Set.unmodifiable(fields);
    }
    final once = {for (final n in writeOnce) UnitName.of(n)};
    for (final n in once) {
      if (!declared.containsKey(n)) {
        throw ArgumentError.value(n, 'writeOnce', 'not a unit of $type');
      }
    }
    return RecordSchema._(
        type, Map.unmodifiable(declared), Set.unmodifiable(once));
  }

  /// The type's name, as the app knows it.
  final String type;

  /// Unit → the fields written whole under it. [UnitName.tomb] is not listed.
  final Map<UnitName, Set<String>> units;

  /// Units written once, at birth. The door refuses a write to one of these
  /// that names any write it saw: such a write can only be a birth.
  final Set<UnitName> writeOnce;
}

/// The id and type an [IdentityFamily] reads from an identity.
typedef ResolvedIdentity = ({RecordId id, RecordSchema schema});

/// Reads one family of identities: derives each one's record id and type.
///
/// The app supplies these. Two different identities must never derive the same
/// id; [HashedIdentityFamily] holds to that up to SHA-256.
abstract interface class IdentityFamily {
  /// The value of the identity's `family` field that selects this family.
  String get name;

  /// Whether a write in this family may be unsalted: a birth whose bytes any
  /// device would mint identically, so two devices make one write.
  bool get allowsDeterministicBirth;

  /// The record [identity] names, or null when it is not a valid member of
  /// this family. [identity]'s `family` is already [name].
  ResolvedIdentity? resolve(Identity identity);
}

/// A family whose id is a UUIDv8 of SHA-256 over the identity's canonical text,
/// and whose identity holds exactly [fields], each a non-empty string or an
/// integer.
final class HashedIdentityFamily implements IdentityFamily {
  HashedIdentityFamily({
    required this.name,
    required this.schema,
    required Set<String> fields,
    this.allowsDeterministicBirth = false,
  }) : fields = Set.unmodifiable(fields);

  @override
  final String name;

  final RecordSchema schema;

  /// The identity's fields, `family` excepted.
  final Set<String> fields;

  @override
  final bool allowsDeterministicBirth;

  @override
  ResolvedIdentity? resolve(Identity identity) {
    final keys = identity.fields.json.keys.toSet();
    if (keys.length != fields.length || !keys.containsAll(fields)) return null;
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
      id: RecordId.uuidV8OfSha256(utf8.encode(identity.canonicalText)),
      schema: schema,
    );
  }
}
