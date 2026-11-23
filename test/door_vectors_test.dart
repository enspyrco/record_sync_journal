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
  '"v":2': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"body","v":2}',
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
  'reserved unit name': (
    '{"fields":{},$_id,"kills":[],$_salt,"unit":"_x","v":1}',
    Refusal.unknownUnit
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
      w.runtimeType,
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
  r'0': '72b229db5d16ae4411994e4d95d8d39e8c5ec4b091a4b1ae3c7990279325a6b4',
  r'2^53 - 1':
      'b4753b6903f713040f2594f2d0d79620f119d07ae81de23f34f5b9c8f0f0dd7b',
  r'-(2^53 - 1)':
      '1633a02e3779b49792ca4308ba61fc76b535274e9010cdadef3ab92fd5270800',
  r'non-BMP raw':
      '15b644d0a9725731dc2826b5db7a5333894e39783eb8bcea5840b4c7893c04df',
  r'U+2028 raw':
      '0b4fa6ffd8f3cf043a1a307aad6c73431072db8e096a9bfef2964186a6fc0a09',
  r'\n \t \b \f \r \" \\':
      '45995956cd78c55d50dac323ba5bd722462c5dab73a286ab1043a8445d75f31b',
  r'\u001f': 'b44741b721e493272207b5e3cc92793fe95035dd233d9a8c22965069d0f2301b',
  r'raw DEL':
      'd867c71449451958f14ff02b67cc2007919445b8b9edad93102c33b3278ac04c',
  r'nested list and map':
      '7068b4e83aba20c31f79dd111892e988b62bae6126d81474b488d5506cd5dd7d',
  r'sorted kills':
      'bfab35f891482a040070ec919b2ae02227b16f5701cfca43ac39e0dcc055e4d5',
  r'delete with sorted saw':
      '27b122cc215f1d6d3c9f517dd7bdbe08dee6768bc6103dedf786dacea2d3e996',
  r'delete with empty saw':
      '2328f714ac1e81134f11de61f700c2420677c1da64fcd567073d860b1193d23a',
  r'restore':
      '972a3a85bf408ae4012f7315001baa0f6a4e013ed4e12c71066aa93d4a0d717b',
  r'deterministic birth':
      'e266d9c8f8c8fb8b3a1a78e45a8723dc20476694cc8f18ef01aeee416f690065',
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
