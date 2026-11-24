// C11: every vector gets the same verdict, and if admitted the same parsed
// values, on the VM, dart2js and dart2wasm. The expectations are literal, so
// one run per compiler is the cross-platform comparison:
//
//   dart test
//   dart test -p chrome
//   dart test -p chrome -c dart2wasm
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:record_sync_journal/record_sync_journal.dart';
import 'package:test/test.dart';

import 'fixtures/notes.dart';

const _salt = '"salt":"00000000000000000000000000000000"';
const _id = '"identity":{"family":"note","nonce":"n1"}';
const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A body write whose `fields` text is [fields].
String _bodyWith(String fields) =>
    '{"fields":$fields,$_id,"kills":[],$_salt,"unit":"body","v":1}';

String _bodyN(String n) => _bodyWith('{"n":$n}');
String _bodyText(String json) => _bodyWith('{"text":$json}');

String _tomb(bool deleted, {String? kills, String? saw}) =>
    '{"fields":{"_deleted":$deleted},$_id,"kills":[${kills ?? ''}],$_salt'
    '${saw == null ? '' : ',"saw":[$saw]'},"unit":"_tomb","v":1}';

/// A JSON `\u` escape of [hex], built from parts so no tool folds it into the
/// character it names.
String _esc(String hex) => '${String.fromCharCode(0x5C)}u$hex';

/// The vectors that are text; byte-level ones are below.
final Map<String, (String, Refusal?)> _textVectors = {
  // Numbers.
  '1000.0': (_bodyN('1000.0'), Refusal.notCanonical),
  '1e3': (_bodyN('1e3'), Refusal.notCanonical),
  '1E400': (_bodyN('1E400'), Refusal.notCanonical),
  '1.5': (_bodyN('1.5'), Refusal.notCanonical),
  '-0': (_bodyN('-0'), Refusal.notCanonical),
  '0': (_bodyN('0'), null),
  '2^53 - 1': (_bodyN('9007199254740991'), null),
  '-(2^53 - 1)': (_bodyN('-9007199254740991'), null),
  '2^53': (_bodyN('9007199254740992'), Refusal.notCanonical),
  '2^53 + 1': (_bodyN('9007199254740993'), Refusal.notCanonical),
  '-(2^53 + 1)': (_bodyN('-9007199254740993'), Refusal.notCanonical),
  '"v":1.0': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":1.0}',
    Refusal.notCanonical
  ),
  // `v` is read before the v=1 grammar: any other integer is a newer wire,
  // whatever its keys; only a missing or non-integer `v` is malformed.
  '"v":2': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":2}',
    Refusal.unknownVersion
  ),
  '"v":2 with a key v=1 lacks': (
    '{"extra":1,"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":2}',
    Refusal.unknownVersion
  ),
  '"v":2 with v=1 keys missing': ('{"v":2}', Refusal.unknownVersion),
  // Versions only rise from 1, so no build ever wrote these.
  '"v":0': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":0}',
    Refusal.schema
  ),
  '"v":-1': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":-1}',
    Refusal.schema
  ),
  'no v': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body"}',
    Refusal.schema
  ),
  '"v":"1"': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":"1"}',
    Refusal.schema
  ),
  '"v":true': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":true}',
    Refusal.schema
  ),
  // Strings.
  'escaped lone high surrogate': (_bodyText(r'"\ud800"'), Refusal.notCanonical),
  'escaped lone low surrogate': (_bodyText(r'"\udc00"'), Refusal.notCanonical),
  'escaped surrogate pair': (
    _bodyText('"${_esc('d83d')}${_esc('de00')}"'),
    Refusal.notCanonical
  ),
  'non-BMP raw': (_bodyText('"😀𝄞"'), null),
  'U+2028 raw': (_bodyText('"  "'), null),
  'U+2028 escaped': (_bodyText('"${_esc('2028')}"'), Refusal.notCanonical),
  r'\n \t \b \f \r \" \\': (_bodyText(r'"\n\t\b\f\r\"\\"'), null),
  r'\u000a for \n': (_bodyText(r'"\u000a"'), Refusal.notCanonical),
  r'\u001f': (_bodyText(r'"\u001f"'), null),
  r'\u001F uppercase': (_bodyText(r'"\u001F"'), Refusal.notCanonical),
  r'\/': (_bodyText(r'"a\/b"'), Refusal.notCanonical),
  'raw DEL': (_bodyText('"\u007f"'), null),
  // Form.
  'reordered keys': (
    '{$_id,"fields":{},"kills":[],$_salt,"unit":"body","v":1}',
    Refusal.notCanonical
  ),
  'reordered field keys': (
    _bodyWith('{"text":"a","n":1}'),
    Refusal.notCanonical
  ),
  'duplicate key': (_bodyWith('{"n":1,"n":1}'), Refusal.notCanonical),
  'whitespace': (
    '{"fields": {},$_id,"kills":[],$_salt,"unit":"body","v":1}',
    Refusal.notCanonical
  ),
  'trailing newline': ('${_bodyN('1')}\n', Refusal.notCanonical),
  'not JSON': ('{"fields":', Refusal.notJson),
  'top-level list': ('[]', Refusal.notAnObject),
  'nested list and map': (
    _bodyWith('{"n":[1,[true,null],{"a":"b"}],"tags":["x","y"]}'),
    null
  ),
  // Nesting: the frame's own two levels plus the value's.
  'nested to the bound': (_bodyWith('{"n":${'[' * 62}${']' * 62}}'), null),
  'nested one past the bound': (
    _bodyWith('{"n":${'[' * 63}${']' * 63}}'),
    Refusal.tooDeep
  ),
  'two siblings each nested to the bound': (
    _bodyWith('{"n":[${'[' * 61}${']' * 61},${'[' * 61}${']' * 61}]}'),
    null
  ),
  'nested 20000 deep': (
    _bodyWith('{"n":${'[' * 20000}${']' * 20000}}'),
    Refusal.tooDeep
  ),
  'brackets inside a string do not nest': (_bodyText('"${'[{' * 100}"'), null),
  'an escaped quote does not end the string': (
    _bodyText('"${String.fromCharCode(0x5C)}"${'[' * 100}"'),
    null
  ),
  // Kills and saw.
  'sorted kills': (
    '{"fields":{},$_id,"kills":["$_a","$_b"],$_salt,"unit":"body","v":1}',
    null
  ),
  'unsorted kills': (
    '{"fields":{},$_id,"kills":["$_b","$_a"],$_salt,"unit":"body","v":1}',
    Refusal.writeIds
  ),
  'duplicate kills': (
    '{"fields":{},$_id,"kills":["$_a","$_a"],$_salt,"unit":"body","v":1}',
    Refusal.writeIds
  ),
  'uppercase kill': (
    '{"fields":{},$_id,"kills":["${_a.toUpperCase()}"],$_salt,"unit":"body","v":1}',
    Refusal.writeIds
  ),
  'delete with sorted saw': (_tomb(true, saw: '"$_a","$_b"'), null),
  'delete with empty saw': (_tomb(true, saw: ''), null),
  'unsorted saw': (_tomb(true, saw: '"$_b","$_a"'), Refusal.writeIds),
  'delete without saw': (_tomb(true), Refusal.saw),
  'saw on a restore': (_tomb(false, saw: ''), Refusal.saw),
  'restore': (_tomb(false, kills: '"$_a"'), null),
  'saw on a content write': (
    '{"fields":{},$_id,"kills":[],$_salt,"saw":[],"unit":"body","v":1}',
    Refusal.saw
  ),
  // Schema.
  'extra key': (
    '{"extra":1,"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":1}',
    Refusal.schema
  ),
  'missing kills': (
    '{"fields":{},$_id,$_salt,"unit":"body","v":1}',
    Refusal.schema
  ),
  'no salt, ordinary family': (
    '{"fields":{},$_id,"kills":[],"unit":"body","v":1}',
    Refusal.salt
  ),
  'short salt': (
    '{"fields":{},$_id,"kills":[],"salt":"00","unit":"body","v":1}',
    Refusal.salt
  ),
  'deterministic birth': (
    '{"fields":{},"identity":{"cause":"c","family":"derivedNote"},'
        '"kills":[],"unit":"body","v":1}',
    null
  ),
  'deterministic birth that kills': (
    '{"fields":{},"identity":{"cause":"c","family":"derivedNote"},'
        '"kills":["$_a"],"unit":"body","v":1}',
    Refusal.salt
  ),
  'unknown family': (
    '{"fields":{},"identity":{"family":"nope","nonce":"n1"},"kills":[],'
        '$_salt,"unit":"body","v":1}',
    Refusal.unknownFamily
  ),
  'invalid identity': (
    '{"fields":{},"identity":{"family":"note","other":"n1"},"kills":[],'
        '$_salt,"unit":"body","v":1}',
    Refusal.invalidIdentity
  ),
  'unknown unit': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"nope","v":1}',
    Refusal.unknownUnit
  ),
  // No build can declare it, so it is malformed, never a newer unit.
  'reserved unit name': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"_x","v":1}',
    Refusal.schema
  ),
  'empty unit name': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"","v":1}',
    Refusal.schema
  ),
  // A malformed write is refused as malformed whatever families the reader
  // has: an unknown family never hides it behind a reason reads skip.
  'unknown family, reserved unit name': (
    '{"fields":{},"identity":{"family":"nope","nonce":"n1"},"kills":[],'
        '$_salt,"unit":"_x","v":1}',
    Refusal.schema
  ),
  'unknown family, reserved field name': (
    '{"fields":{"_f":1},"identity":{"family":"nope","nonce":"n1"},'
        '"kills":[],$_salt,"unit":"body","v":1}',
    Refusal.fields
  ),
  'unknown family, saw on a content write': (
    '{"fields":{},"identity":{"family":"nope","nonce":"n1"},"kills":[],'
        '$_salt,"saw":[],"unit":"body","v":1}',
    Refusal.saw
  ),
  'unknown family, tomb not boolean': (
    '{"fields":{"_deleted":1},"identity":{"family":"nope","nonce":"n1"},'
        '"kills":[],$_salt,"unit":"_tomb","v":1}',
    Refusal.fields
  ),
  'unknown family, unsalted write that kills': (
    '{"fields":{},"identity":{"family":"nope","nonce":"n1"},'
        '"kills":["$_a"],"unit":"body","v":1}',
    Refusal.salt
  ),
  'unknown unit, unsalted write that kills': (
    '{"fields":{},"identity":{"cause":"c","family":"derivedNote"},'
        '"kills":["$_a"],"unit":"nope","v":1}',
    Refusal.salt
  ),
  'unknown unit, unsalted in a family without births': (
    '{"fields":{},$_id,"kills":[],"unit":"nope","v":1}',
    Refusal.salt
  ),
  'unknown family, unsalted tomb': (
    '{"fields":{"_deleted":false},"identity":{"family":"nope","nonce":"n1"},'
        '"kills":[],"unit":"_tomb","v":1}',
    Refusal.salt
  ),
  'undeclared field': (_bodyWith('{"zzz":1}'), Refusal.fields),
  'tomb with a second field': (
    '{"fields":{"_deleted":true,"x":1},$_id,"kills":[],$_salt,"saw":[],'
        '"unit":"_tomb","v":1}',
    Refusal.fields
  ),
  'tomb not boolean': (
    '{"fields":{"_deleted":1},$_id,"kills":[],$_salt,"unit":"_tomb","v":1}',
    Refusal.fields
  ),
};

List<int> _raw(String before, List<int> middle, String after) =>
    [...utf8.encode(before), ...middle, ...utf8.encode(after)];

final Map<String, (List<int>, Refusal?)> _byteVectors = {
  'lone surrogate, raw (ED A0 80)': (
    _raw('{"fields":{"text":"', [0xED, 0xA0, 0x80],
        '"},$_id,"kills":[],$_salt,"unit":"body","v":1}'),
    Refusal.malformedUtf8
  ),
  'overlong slash (C0 AF)': (
    _raw('{"fields":{"text":"', [0xC0, 0xAF],
        '"},$_id,"kills":[],$_salt,"unit":"body","v":1}'),
    Refusal.malformedUtf8
  ),
  'truncated sequence (E2 82)': (
    _raw('{"fields":{"text":"', [0xE2, 0x82],
        '"},$_id,"kills":[],$_salt,"unit":"body","v":1}'),
    Refusal.malformedUtf8
  ),
  'raw control byte in a string': (
    _raw('{"fields":{"text":"', [0x1F],
        '"},$_id,"kills":[],$_salt,"unit":"body","v":1}'),
    Refusal.notJson
  ),
  'byte-order mark': (
    [0xEF, 0xBB, 0xBF, ...utf8.encode(_bodyN('1'))],
    Refusal.notAnObject
  ),
  'empty': (<int>[], Refusal.notAnObject),
};

/// What an admitted write parsed to, as text every platform must agree on.
String _parsed(UnitWrite w) => [
      switch (w) {
        ContentWrite() => 'content',
        DeleteWrite() => 'delete',
        RestoreWrite() => 'restore',
      },
      w.record,
      w.identity.canonicalText,
      w.unit,
      w.fields.text,
      w.kills.join(','),
      if (w is DeleteWrite) 'saw=${w.saw.join(',')}',
      w.salt ?? 'unsalted',
    ].join(' | ');

/// SHA-256 of each admitted vector's [_parsed] text, as the VM produced it.
/// Every other platform must produce exactly these. Hashes, so that no tool
/// can fold an escape in a golden into the character it names.
const _expectedParsed = <String, String>{
  r'0': '3cb93c7729cede86027c69cf634feca8fce9f23b40fa2e957f69decf787933f4',
  r'2^53 - 1':
      'aacba5ecb32f7088fbe9e809592959122a0ceec176e512e1b5c27b9d398bcce2',
  r'-(2^53 - 1)':
      'c3eaad83dfd30cf2ddab916fc61d420c642ab2af7d8fa50e592c3cca325a5f47',
  r'non-BMP raw':
      '8bd3fe6096dee511d6e0df22965b51edd36bb8fe9491b708883b200063bb2934',
  r'U+2028 raw':
      '5f3609c1319c85b7f2ea1ac81566b88f2c10f967085baa69577c987e2792b7c9',
  r'\n \t \b \f \r \" \\':
      '4b825bcceefad25e80529a99965a54d29f7add0b38f5f973093386d309a86b3e',
  r'\u001f': '5372966166d51934e9d57a14f081a44bfab88bb39cc5de4bb9cd234c8f221997',
  r'raw DEL':
      '13f650a91427d0a15463b5b1ad827da6c37a0b4f9214dfa8c743c6574f545db1',
  r'nested list and map':
      '5bb8cec85ce648da84e1ddb9ca5dcf5cc7345084c51aab60dcc4addcaf6bd754',
  r'nested to the bound':
      'c8827c49a85b59723fa33ac6ac06341eb0c5e654ce8877c074837c9805d57db4',
  r'two siblings each nested to the bound':
      '2a0809ab43e47acd30adab6bd6a6c8e85d38b45ea5602a37f60e232cf14ee0e4',
  r'brackets inside a string do not nest':
      '872b9c9beeed486bb86d81bb0b29392570d441e53e6c5d3e52345863430908e0',
  r'an escaped quote does not end the string':
      '4d14f89eda980b3e5642ced01b8e22bef8ff6d61d68081f7bae8f7968e9c686c',
  r'sorted kills':
      '16e0bb389d037442056f12496bb74f34a4695761ba8c940f342eff2ccf5b4551',
  r'delete with sorted saw':
      '655ff3c3a1d629a1a70c36f604aa2b5f28ae7da4e3c0b24d85a950946126d60c',
  r'delete with empty saw':
      '5c89b4eebf415bff30a0a49886247e1efe8cf7663a48222b1baa531dcd18c969',
  r'restore':
      'e1ef10fcc54b2f216f8c01e1146d636831c63f27e24f873e1d4b1a1337679b8d',
  r'deterministic birth':
      '2c9004ccb6ecade71293c492efedff6adce50c694720f3cd5fd425a5f7f1c5f1',
};

const _dump = false;

void main() {
  group('C11 text vectors', () {
    for (final MapEntry(key: name, value: (text, refusal))
        in _textVectors.entries) {
      test(name, () => _check(name, utf8.encode(text), refusal));
    }
  });
  group('C11 byte vectors', () {
    for (final MapEntry(key: name, value: (bytes, refusal))
        in _byteVectors.entries) {
      test(name, () => _check(name, bytes, refusal));
    }
  });
}

void _check(String name, List<int> bytes, Refusal? refusal) {
  final admission = noteDoor.admit(bytes);
  final id = WriteId.ofBytes(bytes);
  switch (admission) {
    case Refused(:final reason, id: final refusedId):
      expect(reason, refusal,
          reason: 'refused, expected ${refusal ?? 'admit'}');
      expect(refusedId, id);
    case Admitted(:final write):
      expect(refusal, isNull, reason: 'admitted, expected $refusal');
      expect(write.id, id);
      expect(write.bytes, bytes);
      final expected = _expectedParsed[name];
      final digest = sha256.convert(utf8.encode(_parsed(write))).toString();
      if (_dump) print('GOLDEN\t$name\t$digest');
      expect(digest, expected, reason: _parsed(write));
  }
}
