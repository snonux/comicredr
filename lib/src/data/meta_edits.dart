import 'dart:convert';

/// The book facts a person can edit in the library. The names are the
/// `field` values of the `overrides` table in the index and the sidecar.
enum MetaField {
  series('Series'),
  number('Issue'),
  title('Title'),
  volume('Volume'),
  year('Year'),
  writers('Writers'),
  artists('Artists'),
  summary('Summary');

  const MetaField(this.label);

  final String label;

  /// Whole numbers only.
  bool get numeric => this == volume || this == year;

  static MetaField? byName(String name) => values.where((f) => f.name == name).firstOrNull;
}

/// One hand edit to a book fact, kept apart from what the file says so a
/// rescan never undoes it. [value] null clears the fact (a wrong year
/// gone); [fromFile] undoes the edit, and the file's own value shows again.
/// [at] decides between two devices that edited the same fact: the later
/// edit wins, an undo included, which is why an undo is a row and not a
/// deleted one.
///
/// Stored as JSON in the overrides table's `value` column. A bare string
/// there (written by hand with sqlite3) reads as an edit to that value made
/// long ago.
class MetaEdit {
  const MetaEdit(this.value, {required this.at, this.fromFile = false});

  const MetaEdit.undo({required this.at}) : value = null, fromFile = true;

  final String? value;
  final DateTime at;
  final bool fromFile;

  String encode() => jsonEncode({'value': value, 'at': at.millisecondsSinceEpoch, if (fromFile) 'fromFile': true});

  static MetaEdit decode(String raw) {
    try {
      if (jsonDecode(raw) case {'at': final int at} && final Map<String, Object?> m) {
        return MetaEdit(
          m['value'] as String?,
          at: DateTime.fromMillisecondsSinceEpoch(at),
          fromFile: m['fromFile'] == true,
        );
      }
    } on FormatException {
      // A plain value.
    }
    return MetaEdit(raw, at: DateTime.fromMillisecondsSinceEpoch(0));
  }

  @override
  bool operator ==(Object other) =>
      other is MetaEdit && other.value == value && other.at == at && other.fromFile == fromFile;

  @override
  int get hashCode => Object.hash(value, at, fromFile);
}

/// Per fact, the later of two sets of edits (encoded as the overrides table
/// holds them); [b] wins a tie.
Map<String, String> mergeEdits(Map<String, String> a, Map<String, String> b) {
  final out = {...a};
  for (final MapEntry(:key, :value) in b.entries) {
    final have = out[key];
    if (have == null || !MetaEdit.decode(value).at.isBefore(MetaEdit.decode(have).at)) out[key] = value;
  }
  return out;
}

/// The edits in effect from [overrides]: undone ones and unknown fields
/// left out.
Map<MetaField, String?> activeEdits(Map<String, String> overrides) => {
  for (final MapEntry(:key, :value) in overrides.entries)
    if (MetaField.byName(key) case final f?)
      if (MetaEdit.decode(value) case final e when !e.fromFile) f: e.value,
};

/// A people list as typed: comma-separated, trimmed, blanks dropped.
List<String> splitPeople(String? s) =>
    s?.split(',').map((w) => w.trim()).where((w) => w.isNotEmpty).toList() ?? const [];
