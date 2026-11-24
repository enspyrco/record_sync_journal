import 'package:record_sync_journal/record_sync_journal.dart';

Set<FieldName> fieldNames(List<String> names) =>
    {for (final n in names) FieldName.of(n)};

/// A minimal app: one record type with a body unit and a title unit.
final noteSchema = RecordSchema(type: RecordType.of('note'), units: {
  body: fieldNames(['text', 'n', 'tags']),
  title: fieldNames(['title']),
});

final noteFamily = HashedIdentityFamily(
    name: FamilyName.of('note'),
    schema: noteSchema,
    fields: {FieldName.of('nonce')});

/// The same schema in a family whose births may be deterministic.
final derivedNoteFamily = HashedIdentityFamily(
    name: FamilyName.of('derivedNote'),
    schema: noteSchema,
    fields: {FieldName.of('cause')},
    allowsDeterministicBirth: true);

final noteDoor = Door([noteFamily, derivedNoteFamily]);

Identity note(String nonce) =>
    Identity.of(FamilyName.of('note'), {'nonce': nonce});

final body = UnitName.of('body');
final title = UnitName.of('title');
