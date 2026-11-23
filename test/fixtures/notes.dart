import 'package:record_sync_journal/record_sync_journal.dart';

/// A minimal app: one record type with a body unit and a title unit.
final noteSchema = RecordSchema(type: 'note', units: {
  'body': ['text', 'n', 'tags'],
  'title': ['title'],
});

final noteFamily =
    HashedIdentityFamily(name: 'note', schema: noteSchema, fields: {'nonce'});

/// The same schema in a family whose births may be deterministic.
final derivedNoteFamily = HashedIdentityFamily(
    name: 'derivedNote',
    schema: noteSchema,
    fields: {'cause'},
    allowsDeterministicBirth: true);

final noteDoor = Door([noteFamily, derivedNoteFamily]);

Identity note(String nonce) => Identity.of('note', {'nonce': nonce});

final body = UnitName.of('body');
final title = UnitName.of('title');
