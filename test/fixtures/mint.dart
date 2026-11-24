import 'dart:math';

import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'notes.dart';

/// Mints and admits writes as an author would, without a journal.
final class Minter {
  Minter([int seed = 1]) : _random = Random(seed);

  final Random _random;

  UnitWrite admit(UnitWriteDraft d, {Door? door}) {
    final bytes = d.encode(d.salted ? Salt.random(_random) : null);
    return switch ((door ?? noteDoor).admit(bytes)) {
      Admitted(:final write) => write,
      Refused(:final reason) => throw StateError('refused: $reason'),
    };
  }

  UnitWrite edit(Identity id, UnitName unit, Map<String, Object?> fields,
          [Set<UnitWrite> saw = const {}]) =>
      admit(UnitWriteDraft.content(
          identity: id,
          unit: unit,
          fields: fields,
          observedLive: {for (final w in saw) w.id}));

  UnitWrite delete(Identity id,
          {Set<UnitWrite> tomb = const {},
          Set<UnitWrite> content = const {}}) =>
      admit(UnitWriteDraft.delete(
          identity: id,
          observedLiveTomb: {for (final w in tomb) w.id},
          sawContent: {for (final w in content) w.id}));

  UnitWrite restore(Identity id, {Set<UnitWrite> tomb = const {}}) =>
      admit(UnitWriteDraft.restore(
          identity: id, observedLiveTomb: {for (final w in tomb) w.id}));
}

/// A view as text, so two views compare by everything they say.
String describe(RecordView v) {
  final units = [
    for (final u in v.units.keys.toList()..sort())
      '$u: live=${(v.units[u]!.liveIds.toList()..sort()).join(',')} '
          'shown=${v.units[u]!.shown.join(' ')}',
  ];
  final kind = switch (v) {
    DrawnRecord() => 'drawn',
    HiddenRecord() => 'hidden',
    GhostRecord(:final unseen, :final tombContested) =>
      'ghost unseen=${(unseen.toList()..sort()).join(',')} '
          'tombContested=$tombContested',
  };
  return '${v.id} $kind\n${units.join('\n')}';
}

/// A stored record as text, whatever the read found.
String describeRead(RecordRead r) => switch (r) {
      Readable(:final view) =>
        '${describe(view)}${view.unread.isEmpty ? '' : '\nunread=${view.unread.length}'}',
      UnreadRecord(:final id, :final unread) => '$id unread=${unread.length}',
      UnreadableRecord(:final id, :final reason) => '$id unreadable $reason',
    };

/// [record]'s view, or null when nothing is stored; fails the test when the
/// journal left any write out.
Future<RecordView?> viewOf(RecordJournal j, RecordId record) async =>
    switch (await j.read(record)) {
      null => null,
      Readable(:final view) when view.unread.isEmpty => view,
      final other => fail('$record was not read whole: $other'),
    };

/// [record]'s view even when the journal left writes out; fails the test
/// unless at least one stored write was read.
Future<RecordView> readableOf(RecordJournal j, RecordId record) async =>
    switch (await j.read(record)) {
      Readable(:final view) => view,
      final other => fail('$record has nothing readable: $other'),
    };

/// Every stored record's view; fails the test when any is not read whole.
Future<List<RecordView>> viewsOf(RecordJournal j) async => [
      for (final r in await j.readAll())
        switch (r) {
          Readable(:final view) when view.unread.isEmpty => view,
          _ => fail('${r.id} was not read whole: ${describeRead(r)}'),
        },
    ];
