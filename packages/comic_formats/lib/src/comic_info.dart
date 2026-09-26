import 'dart:convert';

import 'document.dart';

/// Parses the ComicRack `ComicInfo.xml` fields the reader uses. A small
/// tolerant scan rather than a full XML parser: scrapers write this file in
/// many slightly broken ways, and a bad field should cost that field only.
ComicMeta parseComicInfo(String xml) {
  String? field(String name) {
    final m = RegExp('<$name>(.*?)</$name>', dotAll: true).firstMatch(xml);
    final v = m == null ? null : _unescape(m.group(1)!.trim());
    return v == null || v.isEmpty ? null : v;
  }

  List<String> people(String name) =>
      field(name)?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList() ?? const [];

  int? frontCover;
  for (final m in RegExp(r'<Page\b([^>]*)/?>').allMatches(xml)) {
    final attrs = m.group(1)!;
    if (RegExp(r'''Type\s*=\s*["']FrontCover["']''').hasMatch(attrs)) {
      final image = RegExp(r'''Image\s*=\s*["'](\d+)["']''').firstMatch(attrs);
      if (image != null) frontCover = int.tryParse(image.group(1)!);
      break;
    }
  }

  return ComicMeta(
    title: field('Title'),
    series: field('Series'),
    number: field('Number'),
    volume: int.tryParse(field('Volume') ?? ''),
    year: int.tryParse(field('Year') ?? ''),
    writers: people('Writer'),
    artists: [...people('Penciller'), ...people('Inker')],
    summary: field('Summary'),
    frontCoverPage: frontCover,
    rightToLeft: field('Manga') == 'YesAndRightToLeft',
  );
}

String _unescape(String s) => s.contains('&') ? unescapeXml(s) : s;

/// Replaces XML's predefined entities and numeric references in [s].
String unescapeXml(String s) => const _XmlUnescape().convert(s);

/// The five predefined XML entities plus numeric references.
class _XmlUnescape extends Converter<String, String> {
  const _XmlUnescape();

  static final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);');

  @override
  String convert(String input) => input.replaceAllMapped(_entity, (m) {
    final e = m.group(1)!;
    return switch (e) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      _ when e.startsWith('#x') => _char(int.tryParse(e.substring(2), radix: 16), m[0]!),
      _ => _char(int.tryParse(e.substring(1)), m[0]!),
    };
  });

  /// The character [code] names, or the reference as written when it names
  /// none: one bad reference should not cost the whole book its metadata.
  static String _char(int? code, String written) =>
      code == null || code > 0x10FFFF ? written : String.fromCharCode(code);
}
