import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';

import 'canonical_json.dart';
import 'values.dart';

/// One admitted unit write: the bytes as received and what they say.
///
/// Only [Door.admit] makes one, so every write a journal holds, local or
/// remote, came through the same parse.
sealed class UnitWrite {
  UnitWrite._({
    required this.bytes,
    required this.id,
    required this.identity,
    required this.record,
    required this.schema,
    required this.unit,
    required this.fields,
    required this.kills,
    required this.salt,
  });

  /// The exact bytes received. Read-only.
  final Uint8List bytes;

  /// SHA-256 of [bytes].
  final WriteId id;

  final Identity identity;

  /// The record [identity] names, as its family derived it.
  final RecordId record;

  final RecordSchema schema;

  final UnitName unit;

  /// The unit's whole field set.
  final CanonicalObject fields;

  /// The writes of this (record, unit) the author saw live and replaces.
  final Set<WriteId> kills;

  /// Null only on a deterministic birth.
  final Salt? salt;

  @override
  bool operator ==(Object other) => other is UnitWrite && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => utf8.decode(bytes);
}

/// A write to one of the record's own units.
final class ContentWrite extends UnitWrite {
  ContentWrite._({
    required super.bytes,
    required super.id,
    required super.identity,
    required super.record,
    required super.schema,
    required super.unit,
    required super.fields,
    required super.kills,
    required super.salt,
  }) : super._();
}

/// `_tomb = true`: the record is deleted, over the content writes in [saw].
final class DeleteWrite extends UnitWrite {
  DeleteWrite._({
    required super.bytes,
    required super.id,
    required super.identity,
    required super.record,
    required super.schema,
    required super.fields,
    required super.kills,
    required super.salt,
    required this.saw,
  }) : super._(unit: UnitName.tomb);

  /// The live content writes the author saw when deleting. A witness, not a
  /// kill: it empties no unit (DESIGN §3.6.5).
  final Set<WriteId> saw;
}

/// `_tomb = false`: the record is restored.
final class RestoreWrite extends UnitWrite {
  RestoreWrite._({
    required super.bytes,
    required super.id,
    required super.identity,
    required super.record,
    required super.schema,
    required super.fields,
    required super.kills,
    required super.salt,
  }) : super._(unit: UnitName.tomb);
}

/// A write before it has bytes: what the author means to write and what they
/// saw. The journal salts and encodes it, then admits the bytes through its
/// door like any other write.
///
/// The factories cover the four writes there are, so a malformed one (a `saw`
/// on an edit, an unsalted edit that kills) cannot be asked for.
final class UnitWriteDraft {
  /// Copies [kills] and [saw], so what the author saw is fixed when the draft
  /// is made, whatever the caller does to its sets afterwards.
  UnitWriteDraft._(this.identity, this.unit, this.fields, Set<WriteId> kills,
      Set<WriteId>? saw, this.salted)
      : kills = Set.unmodifiable(kills),
        saw = saw == null ? null : Set.unmodifiable(saw);

  /// A salted write of [unit]'s whole field set. [observedLive] is the unit's
  /// live set when the operation was computed, never when it is appended.
  factory UnitWriteDraft.content({
    required Identity identity,
    required UnitName unit,
    required Map<String, Object?> fields,
    required Set<WriteId> observedLive,
  }) {
    if (unit.isTomb) {
      throw ArgumentError.value(unit, 'unit', 'use delete or restore');
    }
    return UnitWriteDraft._(
        identity, unit, CanonicalObject.of(fields), observedLive, null, true);
  }

  /// A delete. [observedLiveTomb] is `_tomb`'s live set, which it kills;
  /// [sawContent] is every live write on the record's other units, which it
  /// witnesses.
  factory UnitWriteDraft.delete({
    required Identity identity,
    required Set<WriteId> observedLiveTomb,
    required Set<WriteId> sawContent,
  }) =>
      UnitWriteDraft._(identity, UnitName.tomb, _tombFields(true),
          observedLiveTomb, sawContent, true);

  /// A restore, killing `_tomb`'s live set [observedLiveTomb].
  factory UnitWriteDraft.restore({
    required Identity identity,
    required Set<WriteId> observedLiveTomb,
  }) =>
      UnitWriteDraft._(identity, UnitName.tomb, _tombFields(false),
          observedLiveTomb, null, true);

  /// An unsalted birth that names nothing, so every device minting it makes
  /// the same bytes and therefore one write. Only a family that
  /// [IdentityFamily.allowsDeterministicBirth] admits it.
  factory UnitWriteDraft.deterministicBirth({
    required Identity identity,
    required UnitName unit,
    required Map<String, Object?> fields,
  }) {
    if (unit.isTomb) {
      throw ArgumentError.value(unit, 'unit', 'a birth is a content write');
    }
    return UnitWriteDraft._(
        identity, unit, CanonicalObject.of(fields), const {}, null, false);
  }

  static CanonicalObject _tombFields(bool deleted) =>
      CanonicalObject.of({UnitName.deletedField: deleted});

  final Identity identity;
  final UnitName unit;
  final CanonicalObject fields;
  final Set<WriteId> kills;
  final Set<WriteId>? saw;

  /// False only for a deterministic birth.
  final bool salted;

  /// The canonical bytes, with [salt] when [salted].
  Uint8List encode(Salt? salt) {
    if (salted != (salt != null)) {
      throw ArgumentError.value(salt, 'salt', 'salted is $salted');
    }
    final sawIds = saw;
    return utf8.encode(canonicalJson({
      'v': 1,
      'identity': identity.toJson(),
      'unit': unit.value,
      'fields': fields.json.asUncheckedMap(),
      'kills': _sortedHex(kills),
      if (sawIds != null) 'saw': _sortedHex(sawIds),
      if (salt != null) 'salt': salt.hex,
    }));
  }

  static List<String> _sortedHex(Set<WriteId> ids) =>
      [for (final id in ids.toList()..sort()) id.hex];
}

/// Why the door refused a frame.
enum Refusal {
  /// The first byte is not `{`. Dart's UTF-8 decoder strips a leading
  /// byte-order mark on every platform, so without this test a write and the
  /// same write behind a mark would decode alike but hash to two ids.
  notAnObject,
  malformedUtf8,
  notJson,

  /// The parsed value does not re-encode to exactly the decoded text.
  notCanonical,

  /// A key missing or extra, a value of the wrong type, or `v` not 1.
  schema,

  /// `kills` or `saw` holds an entry that is not a write id, or is not sorted
  /// and unique.
  writeIds,

  /// `saw` on a write that is not a delete, or a delete without it.
  saw,

  /// A missing or malformed salt, other than on a deterministic birth.
  salt,
  unknownFamily,
  invalidIdentity,
  unknownUnit,

  /// A field the unit does not declare, or `_tomb` holding anything but a
  /// boolean `_deleted`.
  fields,

  /// A write to a write-once unit that kills something.
  writeOnce,

  /// Brackets nested deeper than [maxNestingDepth].
  tooDeep,
}

/// What the door made of a frame.
sealed class Admission {
  const Admission();
}

final class Admitted extends Admission {
  const Admitted(this.write);
  final UnitWrite write;
}

final class Refused extends Admission {
  const Refused(this.id, this.reason);

  /// The refused bytes' id: it covers exactly what was refused.
  final WriteId id;
  final Refusal reason;

  @override
  String toString() => 'Refused($reason, $id)';
}

/// Admits or refuses unit-write bytes, as a function of the bytes alone
/// (DESIGN §1.1).
final class Door {
  /// A door reading [families]. Throws an [ArgumentError] when two share a
  /// name.
  Door(Iterable<IdentityFamily> families) : _families = _byName(families);

  static Map<String, IdentityFamily> _byName(Iterable<IdentityFamily> fs) {
    final byName = <String, IdentityFamily>{};
    for (final f in fs) {
      if (byName.containsKey(f.name)) {
        throw ArgumentError.value(f.name, 'families', 'named twice');
      }
      byName[f.name] = f;
    }
    return Map.unmodifiable(byName);
  }

  final Map<String, IdentityFamily> _families;

  static const _keys = {
    'v',
    'identity',
    'unit',
    'fields',
    'kills',
    'saw',
    'salt'
  };
  static const _required = {'v', 'identity', 'unit', 'fields', 'kills'};

  /// The record [identity] names, or null when no family here reads it.
  ResolvedIdentity? resolve(Identity identity) {
    final family = _families[identity.family];
    final read = family?.resolve(identity);
    if (family == null || read == null || read.key.isEmpty) return null;
    return (
      id: RecordId.of(family: family.name, key: read.key),
      schema: read.schema,
    );
  }

  /// Admits [frame] or says why not. In order: hash before any decode; strict
  /// UTF-8; JSON; the canonical re-encode test; then the exact schema.
  ///
  /// The canonical test comes before the schema so that the schema only ever
  /// sees a parsed value that is a function of the text: from there on no
  /// platform can disagree, about the verdict or the reason.
  Admission admit(List<int> frame) {
    final bytes = Uint8List.fromList(frame);
    final id = WriteId.ofBytes(bytes);
    Refused refuse(Refusal r) => Refused(id, r);

    if (bytes.isEmpty || bytes[0] != 0x7B) return refuse(Refusal.notAnObject);
    if (!_nestsWithin(bytes, maxNestingDepth)) return refuse(Refusal.tooDeep);
    final String text;
    try {
      text = const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return refuse(Refusal.malformedUtf8);
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return refuse(Refusal.notJson);
    }
    if (canonicalJsonOrNull(parsed) != text) {
      return refuse(Refusal.notCanonical);
    }
    final wire = JsonObject.parse(parsed);
    if (wire == null) return refuse(Refusal.schema);
    final keys = wire.keys.toSet();
    if (!_keys.containsAll(keys) || !keys.containsAll(_required)) {
      return refuse(Refusal.schema);
    }

    final identityWire = JsonObject.parse(wire.raw('identity'));
    final fieldsWire = JsonObject.parse(wire.raw('fields'));
    final (v, unitWire, killsWire) =
        (wire.raw('v'), wire.raw('unit'), wire.raw('kills'));
    if (v is! int || v != 1) return refuse(Refusal.schema);
    if (identityWire == null ||
        unitWire is! String ||
        fieldsWire == null ||
        killsWire is! List<Object?>) {
      return refuse(Refusal.schema);
    }

    final kills = _sortedIds(killsWire);
    if (kills == null) return refuse(Refusal.writeIds);

    final Salt? salt;
    switch (wire.raw('salt')) {
      case null when !wire.has('salt'):
        salt = null;
      case String s when Salt.parse(s) != null:
        salt = Salt.parse(s);
      default:
        return refuse(Refusal.salt);
    }

    final identity = Identity.parse(identityWire);
    if (identity == null) return refuse(Refusal.schema);
    final family = _families[identity.family];
    if (family == null) return refuse(Refusal.unknownFamily);
    final resolved = resolve(identity);
    if (resolved == null) return refuse(Refusal.invalidIdentity);
    final schema = resolved.schema;

    final fields = CanonicalObject.parse(fieldsWire.asUncheckedMap());
    if (fields == null) return refuse(Refusal.schema);

    final hasSaw = wire.has('saw');
    if (unitWire == UnitName.tomb.value) {
      if (fieldsWire.keys.length != 1) return refuse(Refusal.fields);
      final deleted = fieldsWire.raw(UnitName.deletedField);
      if (deleted is! bool) return refuse(Refusal.fields);
      if (salt == null) return refuse(Refusal.salt);
      if (deleted) {
        final sawWire = wire.raw('saw');
        if (!hasSaw || sawWire is! List<Object?>) return refuse(Refusal.saw);
        final saw = _sortedIds(sawWire);
        if (saw == null) return refuse(Refusal.writeIds);
        return Admitted(DeleteWrite._(
          bytes: bytes.asUnmodifiableView(),
          id: id,
          identity: identity,
          record: resolved.id,
          schema: schema,
          fields: fields,
          kills: kills,
          salt: salt,
          saw: saw,
        ));
      }
      if (hasSaw) return refuse(Refusal.saw);
      return Admitted(RestoreWrite._(
        bytes: bytes.asUnmodifiableView(),
        id: id,
        identity: identity,
        record: resolved.id,
        schema: schema,
        fields: fields,
        kills: kills,
        salt: salt,
      ));
    }

    if (hasSaw) return refuse(Refusal.saw);
    final unit = UnitName.parse(unitWire);
    final declared = unit == null ? null : schema.units[unit];
    if (unit == null || declared == null) return refuse(Refusal.unknownUnit);
    final names = {for (final k in fieldsWire.keys) FieldName.parse(k)};
    if (!declared.containsAll(names)) return refuse(Refusal.fields);
    if (salt == null &&
        (kills.isNotEmpty || !family.allowsDeterministicBirth)) {
      return refuse(Refusal.salt);
    }
    if (schema.writeOnce.contains(unit) && kills.isNotEmpty) {
      return refuse(Refusal.writeOnce);
    }
    return Admitted(ContentWrite._(
      bytes: bytes.asUnmodifiableView(),
      id: id,
      identity: identity,
      record: resolved.id,
      schema: schema,
      unit: unit,
      fields: fields,
      kills: kills,
      salt: salt,
    ));
  }

  /// Whether no bracket in [bytes] opens deeper than [limit], counting only
  /// brackets outside strings. Runs before any decoder sees the frame, so a
  /// deep frame is refused in one pass and never recursed into.
  static bool _nestsWithin(Uint8List bytes, int limit) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final b in bytes) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (b == 0x5C) {
          escaped = true;
        } else if (b == 0x22) {
          inString = false;
        }
        continue;
      }
      switch (b) {
        case 0x22:
          inString = true;
        case 0x7B || 0x5B:
          if (++depth > limit) return false;
        case 0x7D || 0x5D:
          depth--;
      }
    }
    return true;
  }

  /// The ids in [wire], or null unless every entry is a write id and they are
  /// strictly ascending.
  static Set<WriteId>? _sortedIds(List<Object?> wire) {
    final ids = <WriteId>{};
    WriteId? previous;
    for (final entry in wire) {
      final id = entry is String ? WriteId.parse(entry) : null;
      if (id == null) return null;
      if (previous != null && previous.compareTo(id) >= 0) return null;
      ids.add(id);
      previous = id;
    }
    return Set.unmodifiable(ids);
  }
}
