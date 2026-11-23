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
  // Nesting: the frame's own two levels plus the value's.
  'nested to the bound': (_bodyWith('{"n":${'[' * 62}${']' * 62}}'), null),
  'nested one past the bound': (
    _bodyWith('{"n":${'[' * 63}${']' * 63}}'),
    Refusal.tooDeep
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
  r'0': '240ba5f4679d3860092099d6785377dfd2fa53658516109b168d395eb7871751',
  r'2^53 - 1':
      '417ea348927c4b64bec36cf0ca9654c9d0769b1eae0622ae407b23852d98bc7a',
  r'-(2^53 - 1)':
      '082a91f5e5f7d3c42eb373331f96e970e570dcbbdcd3aaf23cd2e955df8baf7c',
  r'non-BMP raw':
      '342eb468a5e3caef99ffc7854efb8f1fe1c0a4794a385d45df0711088f65ac2e',
  r'U+2028 raw':
      'e3e95cf88ebfc12ce7c625694aa0500c38ddb98f3d61a1e025eb97620f03831d',
  r'\n \t \b \f \r \" \\':
      '0f907b5814098f657bfd55fe431a36cc43d603361d08e8f3cecbabfcf1dd614a',
  r'\u001f': '3678d7289c9eb1512c0294687117e663b48c4fec658de27a98d87841a04f6920',
  r'raw DEL':
      'e717a3add80b2ac7ee992855c27fa7fcebfdd4ead4f1bf184442c591a3199c20',
  r'nested list and map':
      '88f8e4bd9a17158dabfea873c44222d09952befe5962b21367be71d5a7fb99ca',
  r'nested to the bound':
      '40d54cecebd4250ac9dc8cc3aa7efa951c42cb8ca40b3f092e8f13d65b4a0c78',
  r'brackets inside a string do not nest':
      'f32e86958c1bc3716fd525e0e04f0aad093771f48f7a689fb26933a114b2df30',
  r'an escaped quote does not end the string':
      'b3964e285f0a56bbdb5005d8eae7f3df361a3bfff44cef87c654df290c03815c',
  r'sorted kills':
      'ddc8638f92f90461dc40de9304b982ca1605566ebd5114ad93d6d85a92d526ad',
  r'delete with sorted saw':
      'a9cdf8ca4c57803c59fc49bdb3df552e0929ebb1bcfc2f64b17faeeacd9589d8',
  r'delete with empty saw':
      'ced22a4b8d0793099e440d116b8aeedaaaa8ac11693346e12041674f1c0036ab',
  r'restore':
      'b184d1aaa8b9cfc12f4cb72cc2a208a7a5fd41f56a0063db391ae6f6902d8030',
  r'deterministic birth':
      '2a751c69b0c42c0c3c0a2e250fc22c6a39d351f69d240a6b68270adea987f471',
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
