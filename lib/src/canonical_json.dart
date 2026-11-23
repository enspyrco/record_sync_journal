/// The one text form of a value: object keys sorted, no whitespace, no doubles.
///
/// The domain is integers with `|n| ≤ 2^53 − 1`, strings without lone
/// surrogates, booleans, null, and lists and string-keyed maps of those. Because
/// no double can appear, every platform writes a value identically, and two
/// values are equal exactly when their canonical texts are.
library;

/// The largest integer every platform holds exactly: `2^53 − 1`.
const int maxSafeInteger = 9007199254740991;

/// The deepest a canonical value nests lists and maps. Deeper is outside the
/// domain, so walking a value never recurses past this.
const int maxNestingDepth = 64;

/// [value]'s canonical text, or null when [value] is outside the domain.
String? canonicalJsonOrNull(Object? value) {
  final out = StringBuffer();
  return _write(value, out, 0) ? out.toString() : null;
}

/// [value]'s canonical text. Throws an [ArgumentError] when [value] is outside
/// the domain (a double, a lone surrogate, a non-string key, an integer past
/// 2^53 − 1, nesting past [maxNestingDepth], or any other type).
String canonicalJson(Object? value) =>
    canonicalJsonOrNull(value) ??
    (throw ArgumentError.value(
        value, 'value', 'outside canonical JSON (no doubles, |n| ≤ 2^53 − 1)'));

bool _write(Object? value, StringBuffer out, int depth) {
  switch (value) {
    case null:
      out.write('null');
    case bool b:
      out.write(b ? 'true' : 'false');
    // `is int` comes before any other number test: on the web `1 is double` is
    // also true, and a whole number there must still count as an integer.
    case int n:
      if (n > maxSafeInteger || n < -maxSafeInteger) return false;
      // On the web an integer can be negative zero; it has one text, `0`.
      out.write(n == 0 ? '0' : n.toString());
    case String s:
      if (!_writeString(s, out)) return false;
    case List<Object?> list:
      if (depth >= maxNestingDepth) return false;
      out.write('[');
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',');
        if (!_write(list[i], out, depth + 1)) return false;
      }
      out.write(']');
    case Map<String, Object?> map:
      if (depth >= maxNestingDepth) return false;
      final keys = map.keys.toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        if (!_writeString(keys[i], out)) return false;
        out.write(':');
        if (!_write(map[keys[i]], out, depth + 1)) return false;
      }
      out.write('}');
    default:
      return false;
  }
  return true;
}

/// Escapes `"`, `\` and the control characters, and nothing else. A lone
/// surrogate has no UTF-8 form, so a string holding one is outside the domain.
bool _writeString(String s, StringBuffer out) {
  out.write('"');
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) return false;
      out.writeCharCode(c);
      out.writeCharCode(next);
      i++;
      continue;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) return false;
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (c < 0x20) {
          out.write(r'\u00');
          out.write(c.toRadixString(16).padLeft(2, '0'));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
  return true;
}
