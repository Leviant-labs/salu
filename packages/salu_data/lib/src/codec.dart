/// Small JSON helpers shared by the repositories.
///
/// Stored payloads are read defensively: a row written by a newer build, or a
/// hand-edited export, degrades to a safe empty value instead of throwing and
/// bricking the diary.
library;

import 'dart:convert';

/// Decodes a JSON object; anything else becomes an empty map.
Map<String, Object?> decodeJsonMap(String json) {
  final decoded = jsonDecode(json);
  if (decoded is Map<String, Object?>) return decoded;
  if (decoded is Map) return decoded.cast<String, Object?>();
  return const <String, Object?>{};
}

/// Decodes a JSON array of strings, dropping non-strings.
Set<String> decodeStringSet(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! List) return const <String>{};
  return {
    for (final value in decoded)
      if (value is String) value,
  };
}

/// Resolves an enum by its `name`, falling back when the stored value is unknown.
T enumByWire<T extends Enum>(List<T> values, String wire, T fallback) {
  for (final value in values) {
    if (value.name == wire) return value;
  }
  return fallback;
}
