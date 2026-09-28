/// Defensive readers for values decoded out of a yt-dlp `-J` payload.
///
/// A site controls the shape of that payload, so a field is never assumed to
/// hold the type the documentation claims. `as List?` throws a `TypeError` on a
/// string where a list was expected, which would crash the app mid-parse on a
/// broken or hostile response; these helpers return an empty result instead,
/// so one odd key yields a missing list rather than a lost download.
library;

/// Reads [value] as a list of [T], or an empty list when it is anything else
/// (including `null`, which yt-dlp emits for fields it did not resolve).
List<T> jsonList<T>(Object? value) {
  if (value is! List) return <T>[];
  return value.whereType<T>().toList();
}

/// Reads [value] as a map with string keys, or an empty map.
Map<String, dynamic> jsonMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  return Map<String, dynamic>.from(value);
}

/// Reads [value] as a number, or null.
num? jsonNum(Object? value) => value is num ? value : null;

/// Reads [value] as a non-empty string, or null.
String? jsonString(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  return null;
}
