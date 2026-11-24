// Engram's record types and units, from
// https://github.com/enspyrco/engram/issues/177#issuecomment-7090483039,
// declared against the package as the genericity test. Engram owns the real
// ones; these are fixtures.
import 'dart:convert';

import 'package:record_sync_journal/record_sync_journal.dart';

Map<UnitName, Set<FieldName>> _units(Map<String, List<String>> units) => {
      for (final MapEntry(:key, :value) in units.entries)
        UnitName.of(key): {for (final f in value) FieldName.of(f)},
    };

final concept = RecordSchema(
    type: RecordType.of('concept'),
    units: _units({
      'body': [
        'name',
        'description',
        'sourceDocumentId',
        'tags',
        'parentConceptId'
      ],
      // A vector of doubles crosses as integers at engram's ×10000 fixed point.
      'embedding': ['embedding'],
    }));

final relationship = RecordSchema(
    type: RecordType.of('relationship'),
    units: _units({
      'body': ['from', 'to', 'label', 'description', 'type'],
    }));

final quizItem = RecordSchema(
  type: RecordType.of('quizItem'),
  units: _units({
    'content': ['conceptId', 'question', 'answer', 'rubric'],
    'predicted': ['predictedDifficulty'],
  }),
  writeOnce: {UnitName.of('predicted')},
);

final review = RecordSchema(
  type: RecordType.of('review'),
  units: _units({
    'event': ['quizItemId', 'rating', 'reviewedAt', 'desiredRetention'],
  }),
  writeOnce: {UnitName.of('event')},
);

final document = RecordSchema(
    type: RecordType.of('document'),
    units: _units({
      'ingest': ['title', 'updatedAt', 'ingestedAt', 'ingestedText'],
      'collection': ['collectionId', 'collectionName'],
    }));

final topic = RecordSchema(
    type: RecordType.of('topic'),
    units: _units({
      'created': ['createdAt'],
      'name': ['name'],
      'description': ['description'],
      'ingested': ['lastIngestedAt'],
    }));

/// Membership only: the record is its `_tomb`.
final topicDocument =
    RecordSchema(type: RecordType.of('topicDocument'), units: {});

HashedIdentityFamily _nonce(String name, RecordSchema schema) =>
    HashedIdentityFamily(
        name: FamilyName.of(name),
        schema: schema,
        fields: {FieldName.of('nonce')});

/// A document's id is its Outline id, carried in the identity.
final class OutlineDocumentFamily implements IdentityFamily {
  @override
  FamilyName get name => FamilyName.of('document');

  @override
  bool get allowsDeterministicBirth => false;

  @override
  FamilyRecord? resolve(Identity identity) {
    final json = identity.fields.json;
    if (json.keys.length != 1 || json.raw('outlineId') is! String) return null;
    final key = RecordKey.parse(json.string('outlineId'));
    return key == null ? null : (key: key, schema: document);
  }
}

/// A topic's membership of a document, keyed by both. Each part is
/// length-prefixed so no two pairs derive one key (`a__b`+`c` vs `a`+`b__c`).
final class TopicDocumentFamily implements IdentityFamily {
  @override
  FamilyName get name => FamilyName.of('topicDocument');

  @override
  bool get allowsDeterministicBirth => false;

  @override
  FamilyRecord? resolve(Identity identity) {
    final json = identity.fields.json;
    final keys = json.keys.toSet();
    if (keys.length != 2 || !keys.containsAll(['topicId', 'documentId'])) {
      return null;
    }
    if (json.raw('topicId') is! String || json.raw('documentId') is! String) {
      return null;
    }
    final (t, d) = (json.string('topicId'), json.string('documentId'));
    final key =
        t.isEmpty || d.isEmpty ? null : RecordKey.parse('${t.length}:$t:$d');
    return key == null ? null : (key: key, schema: topicDocument);
  }
}

final engramFamilies = <IdentityFamily>[
  _nonce('concept', concept),
  _nonce('relationship', relationship),
  _nonce('quizItem', quizItem),
  _nonce('review', review),
  // The synthetic Again written when re-extraction changes a card's answer:
  // derived from its cause, so two devices making the same change mint one
  // write.
  HashedIdentityFamily(
    name: FamilyName.of('syntheticReview'),
    schema: review,
    fields: {FieldName.of('quizItemId'), FieldName.of('contentSha256')},
    allowsDeterministicBirth: true,
  ),
  OutlineDocumentFamily(),
  _nonce('topic', topic),
  TopicDocumentFamily(),
];

/// The synthetic Again's identity for a card whose content became [content].
Identity syntheticAgain(String quizItemId, Map<String, Object?> content) =>
    Identity.of(FamilyName.of('syntheticReview'), {
      'quizItemId': quizItemId,
      'contentSha256': WriteId.ofBytes(utf8.encode(canonicalJson(content))).hex,
    });
