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
    type: 'concept',
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
    type: 'relationship',
    units: _units({
      'body': ['from', 'to', 'label', 'description', 'type'],
    }));

final quizItem = RecordSchema(
  type: 'quizItem',
  units: _units({
    'content': ['conceptId', 'question', 'answer', 'rubric'],
    'predicted': ['predictedDifficulty'],
  }),
  writeOnce: {UnitName.of('predicted')},
);

final review = RecordSchema(
  type: 'review',
  units: _units({
    'event': ['quizItemId', 'rating', 'reviewedAt', 'desiredRetention'],
  }),
  writeOnce: {UnitName.of('event')},
);

final document = RecordSchema(
    type: 'document',
    units: _units({
      'ingest': ['title', 'updatedAt', 'ingestedAt', 'ingestedText'],
      'collection': ['collectionId', 'collectionName'],
    }));

final topic = RecordSchema(
    type: 'topic',
    units: _units({
      'created': ['createdAt'],
      'name': ['name'],
      'description': ['description'],
      'ingested': ['lastIngestedAt'],
    }));

/// Membership only: the record is its `_tomb`.
final topicDocument = RecordSchema(type: 'topicDocument', units: {});

HashedIdentityFamily _nonce(String name, RecordSchema schema) =>
    HashedIdentityFamily(name: name, schema: schema, fields: {'nonce'});

/// A document's id is its Outline id, carried in the identity.
final class OutlineDocumentFamily implements IdentityFamily {
  @override
  String get name => 'document';

  @override
  bool get allowsDeterministicBirth => false;

  @override
  FamilyRecord? resolve(Identity identity) {
    final json = identity.fields.json;
    if (json.keys.length != 1 || json.raw('outlineId') is! String) return null;
    return (key: json.string('outlineId'), schema: document);
  }
}

/// A topic's membership of a document, keyed by both. Each part is
/// length-prefixed so no two pairs derive one key (`a__b`+`c` vs `a`+`b__c`).
final class TopicDocumentFamily implements IdentityFamily {
  @override
  String get name => 'topicDocument';

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
    if (t.isEmpty || d.isEmpty) return null;
    return (key: '${t.length}:$t:$d', schema: topicDocument);
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
    name: 'syntheticReview',
    schema: review,
    fields: {'quizItemId', 'contentSha256'},
    allowsDeterministicBirth: true,
  ),
  OutlineDocumentFamily(),
  _nonce('topic', topic),
  TopicDocumentFamily(),
];

/// The synthetic Again's identity for a card whose content became [content].
Identity syntheticAgain(String quizItemId, Map<String, Object?> content) =>
    Identity.of('syntheticReview', {
      'quizItemId': quizItemId,
      'contentSha256': WriteId.ofBytes(utf8.encode(canonicalJson(content))).hex,
    });
