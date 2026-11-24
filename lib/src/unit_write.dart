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
        identity, unit, _unitFields(fields), observedLive, null, true);
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
        identity, unit, _unitFields(fields), const {}, null, false);
  }

  /// [fields] as a unit's field set. In a write, the write object and its
  /// `fields` object take two of [maxNestingDepth]'s levels, so a field value
  /// nests at most 62 deep; deeper is refused here, where the author asked for
  /// it, rather than by the door at write time.
  static CanonicalObject _unitFields(Map<String, Object?> fields) {
    final value = CanonicalObject.of(fields);
    if (!nestsWithin(value.text.codeUnits, maxNestingDepth - 1)) {
      throw ArgumentError.value(fields, 'fields',
          'nests deeper than a write allows (${maxNestingDepth - 2} levels)');
    }
    return value;
  }

  static CanonicalObject _tombFields(bool deleted) =>
      CanonicalObject.of({FieldName.deleted.value: deleted});

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

  /// `v` missing, not an integer or below 1, or a v=1 write with a key
  /// missing or extra, or a value of the wrong type.
  schema,

  /// `v` is an integer above 1: a wire this build doesn't know.
  unknownVersion,

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
  tooDeep;

  /// A refusal a newer build's write can cause in this one. Apps may only add
  /// families and units, and every wire keeps an integer `v`, so these three
  /// are the only ones (schema-evolution DESIGN §1, §2).
  bool get isNewerSchema => switch (this) {
        unknownFamily || unknownUnit || unknownVersion => true,
        notAnObject ||
        malformedUtf8 ||
        notJson ||
        notCanonical ||
        schema ||
        writeIds ||
        saw ||
        salt ||
        invalidIdentity ||
        fields ||
        writeOnce ||
        tooDeep =>
          false,
      };
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

  static Map<FamilyName, IdentityFamily> _byName(Iterable<IdentityFamily> fs) {
    final byName = <FamilyName, IdentityFamily>{};
    for (final f in fs) {
      if (byName.containsKey(f.name)) {
        throw ArgumentError.value(f.name, 'families', 'named twice');
      }
      byName[f.name] = f;
    }
    return Map.unmodifiable(byName);
  }

  final Map<FamilyName, IdentityFamily> _families;

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
    if (family == null || read == null) return null;
    return (id: RecordId(family.name, read.key), schema: read.schema);
  }

  /// Admits [frame] or says why not. In order: hash before any decode; the
  /// first byte is `{`; bracket depth, counted over the bytes before any
  /// decoder can recurse; strict UTF-8; JSON; the canonical re-encode test;
  /// then the exact schema. The depth count must stay ahead of decoding: a
  /// deep frame crashes or hangs the decoder on some platforms.
  ///
  /// The canonical test comes before the schema so that the schema only ever
  /// sees a parsed value that is a function of the text: from there on no
  /// platform can disagree, about the verdict or the reason.
  Admission admit(List<int> frame) {
    final bytes = Uint8List.fromList(frame);
    final id = WriteId.ofBytes(bytes);
    Refused refuse(Refusal r) => Refused(id, r);

    if (bytes.isEmpty || bytes[0] != 0x7B) return refuse(Refusal.notAnObject);
    if (!nestsWithin(bytes, maxNestingDepth)) return refuse(Refusal.tooDeep);
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
    // `v` is read before any v=1 rule, so a later wire with other keys is
    // refused as a newer version, not as malformed. Versions only rise, so
    // one below 1 was never written by any build.
    final v = wire.raw('v');
    if (v is! int || v < 1) return refuse(Refusal.schema);
    if (v != 1) return refuse(Refusal.unknownVersion);
    final keys = wire.keys.toSet();
    if (!_keys.containsAll(keys) || !keys.containsAll(_required)) {
      return refuse(Refusal.schema);
    }

    final identityWire = JsonObject.parse(wire.raw('identity'));
    final fieldsWire = JsonObject.parse(wire.raw('fields'));
    final (unitWire, killsWire) = (wire.raw('unit'), wire.raw('kills'));
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
    final fields = CanonicalObject.parse(fieldsWire.asUncheckedMap());
    if (fields == null) return refuse(Refusal.schema);

    // Every rule that needs no schema is decided before the family is looked
    // up, so `unknownFamily` and `unknownUnit`, which reads skip as newer,
    // only ever name a well-formed write, whatever families this build has.
    final _Parsed shape;
    switch (_shapeOf(wire, unitWire, fieldsWire, salt, kills)) {
      case _Malformed(:final reason):
        return refuse(reason);
      case final _Parsed parsed:
        shape = parsed;
    }
    final f = _families[identity.family];
    if (f == null) return refuse(Refusal.unknownFamily);
    final r = resolve(identity);
    if (r == null) return refuse(Refusal.invalidIdentity);
    switch (shape) {
      case _DeleteShape(:final saw):
        return Admitted(DeleteWrite._(
          bytes: bytes.asUnmodifiableView(),
          id: id,
          identity: identity,
          record: r.id,
          schema: r.schema,
          fields: fields,
          kills: kills,
          salt: salt,
          saw: saw,
        ));
      case _RestoreShape():
        return Admitted(RestoreWrite._(
          bytes: bytes.asUnmodifiableView(),
          id: id,
          identity: identity,
          record: r.id,
          schema: r.schema,
          fields: fields,
          kills: kills,
          salt: salt,
        ));
      case _ContentShape(:final unit, :final names):
        // Needs the family but not the unit, so it comes before `unknownUnit`.
        if (salt == null && !f.allowsDeterministicBirth) {
          return refuse(Refusal.salt);
        }
        final schema = r.schema;
        final declared = schema.units[unit];
        if (declared == null) return refuse(Refusal.unknownUnit);
        if (!declared.containsAll(names)) return refuse(Refusal.fields);
        if (schema.writeOnce.contains(unit) && kills.isNotEmpty) {
          return refuse(Refusal.writeOnce);
        }
        return Admitted(ContentWrite._(
          bytes: bytes.asUnmodifiableView(),
          id: id,
          identity: identity,
          record: r.id,
          schema: schema,
          unit: unit,
          fields: fields,
          kills: kills,
          salt: salt,
        ));
    }
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

  /// What the write is, by every rule that needs no schema: a delete, a
  /// restore, or content naming a well-formed unit and field names.
  static _ShapeOrMalformed _shapeOf(JsonObject wire, String unitWire,
      JsonObject fieldsWire, Salt? salt, Set<WriteId> kills) {
    final hasSaw = wire.has('saw');
    if (unitWire == UnitName.tomb.value) {
      if (fieldsWire.keys.length != 1) return const _Malformed(Refusal.fields);
      final deleted = fieldsWire.raw(FieldName.deleted.value);
      if (deleted is! bool) return const _Malformed(Refusal.fields);
      if (salt == null) return const _Malformed(Refusal.salt);
      if (!deleted) {
        return hasSaw ? const _Malformed(Refusal.saw) : const _RestoreShape();
      }
      final sawWire = wire.raw('saw');
      if (!hasSaw || sawWire is! List<Object?>) {
        return const _Malformed(Refusal.saw);
      }
      final saw = _sortedIds(sawWire);
      return saw == null
          ? const _Malformed(Refusal.writeIds)
          : _DeleteShape(saw);
    }
    if (hasSaw) return const _Malformed(Refusal.saw);
    // Only a birth may be unsalted, and a birth kills nothing.
    if (salt == null && kills.isNotEmpty) return const _Malformed(Refusal.salt);
    // A name no build can declare is malformed, never a newer unit.
    final unit = UnitName.parse(unitWire);
    if (unit == null) return const _Malformed(Refusal.schema);
    final names = <FieldName>{};
    for (final k in fieldsWire.keys) {
      final name = FieldName.parse(k);
      if (name == null) return const _Malformed(Refusal.fields);
      names.add(name);
    }
    return _ContentShape(unit, names);
  }
}

/// A write's form before its family is consulted, or why it has none.
sealed class _ShapeOrMalformed {
  const _ShapeOrMalformed();
}

final class _Malformed extends _ShapeOrMalformed {
  const _Malformed(this.reason);
  final Refusal reason;
}

/// A well-formed write: a delete, a restore, or content.
sealed class _Parsed extends _ShapeOrMalformed {
  const _Parsed();
}

final class _DeleteShape extends _Parsed {
  const _DeleteShape(this.saw);
  final Set<WriteId> saw;
}

final class _RestoreShape extends _Parsed {
  const _RestoreShape();
}

final class _ContentShape extends _Parsed {
  const _ContentShape(this.unit, this.names);
  final UnitName unit;
  final Set<FieldName> names;
}
