import 'document.dart';

/// Metadata read out of a book's file name, the last resort in the design
/// plan's precedence (section 4): `Series Name v01 #003 (2019).cbz` and its
/// usual mutations, such as `Series_Name_003`, `Series-Name-v2-005`,
/// `Series Name 003 - Title` and `Series Name 01 of 12`.
///
/// [name] is a file or folder name, with or without its extension. The
/// series is never null: a name without a number is a series of one.
ComicMeta parseFileName(String name) {
  var s = name.replaceFirst(RegExp(r'\.(cbz|cbr|cbt|zip|tar|epub|pdf|png|jpe?g|webp)$', caseSensitive: false), '');
  s = s.replaceAll('_', ' ');
  // Names with no spaces use hyphens as spaces: `reptisaurus-v2-005`.
  if (!s.contains(' ')) s = s.replaceAll('-', ' ');

  int? year;
  for (final m in RegExp(r'[(\[]([^)\]]*)[)\]]').allMatches(s)) {
    final y = RegExp(r'\b(19[0-9]{2}|20[0-9]{2})\b').firstMatch(m.group(1)!);
    if (y != null) {
      year ??= int.parse(y.group(1)!);
    }
  }
  // Scanner tags and dates in brackets say nothing about the series.
  s = s.replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), ' ');

  int? volume;
  s = s.replaceFirstMapped(RegExp(r'\b(?:v|vol\.?|volume)\s*(\d{1,3})\b', caseSensitive: false), (m) {
    volume = int.parse(m.group(1)!);
    return ' ';
  });
  s = s.replaceAll(RegExp(r'\s+of\s+\d+\b', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  String? number;
  String? title;
  // `#3`, wherever it is.
  final hash = RegExp(r'#\s*(\d+(?:\.\d+)?[a-z]?)\b', caseSensitive: false).firstMatch(s);
  if (hash != null) {
    number = hash.group(1);
    title = _clean(s.substring(hash.end));
    s = s.substring(0, hash.start);
  } else {
    // A number after the series, maybe followed by ` - Title`.
    final m = RegExp(
      r'^(.*?\S)\s+(?:no\.?\s*|n°\s*|issue\s+|e|ep\.?\s*)?(\d{1,4}(?:\.\d+)?)(?:\s+[-–:]\s+(.*))?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (m != null) {
      s = m.group(1)!;
      number = m.group(2);
      title = _clean(m.group(3) ?? '');
    }
  }
  // `003` is issue 3; a string op, so a name with a huge number still parses.
  if (number != null && RegExp(r'^\d+$').hasMatch(number)) number = number.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  var series = _clean(s);
  // An all-lowercase name reads better in the library title-cased.
  if (series == series.toLowerCase()) {
    series = series.replaceAllMapped(RegExp(r'(^|\s)(\p{L})', unicode: true), (m) => '${m[1]}${m[2]!.toUpperCase()}');
  }
  return ComicMeta(
    series: series.isEmpty ? name : series,
    number: number,
    volume: volume,
    year: year,
    title: title == null || title.isEmpty ? null : title,
  );
}

String _clean(String s) => s.replaceAll(RegExp(r'^[\s\-–:,.]+|[\s\-–:,]+$'), '').trim();

/// The key books are grouped into a series by: case, punctuation, a leading
/// "The" and spacing do not split a series.
String seriesKey(String series) {
  var s = series.toLowerCase().replaceAll('&', ' and ');
  s = s.replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ').trim();
  return s.replaceFirst(RegExp(r'^the '), '');
}

/// An issue number as a number to sort by: `3`, `3.5`, `12a` → 12. Null for
/// numbers that are not numbers (`½`, `Annual`), which sort last.
double? issueOrder(String? number) {
  if (number == null) return null;
  final m = RegExp(r'^-?\d+(?:\.\d+)?').firstMatch(number.trim());
  return m == null ? null : double.parse(m.group(0)!);
}
