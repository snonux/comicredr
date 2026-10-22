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

/// The `field` of the overrides row that says a comic was marked completed
/// (read to the end) by hand, or marked not completed. Not a [MetaField]:
/// it is no fact of the book and not in the edit form, so [activeEdits]
/// leaves it out. It is an overrides row all the same because those have
/// what the mark needs: keyed by content key, dated, the later one winning
/// a sidecar merge ([mergeEdits]) and a settings import, so taking the mark
/// off travels as putting it on does, and Reset everything forgets it.
const completedField = 'completed';

/// The completed mark as an overrides row holds it: true or false as set by
/// hand, null to have no say again (the undo of a first mark), which leaves
/// it to the reading position.
MetaEdit completedEdit(bool? on, {required DateTime at}) =>
    on == null ? MetaEdit.undo(at: at) : MetaEdit(on ? '1' : '0', at: at);

/// What the overrides row [raw] of [completedField] says: completed, not
/// completed, or null for no say (no row, or one undone).
bool? completedMark(String? raw) {
  if (raw == null) return null;
  final e = MetaEdit.decode(raw);
  return e.fromFile ? null : e.value == '1';
}

/// Whether the comic counts as started, independently of its saved place.
/// A dated override, like [completedField], so taking it off reaches other
/// devices too. A qualifying sitting writes true again; null is an undo.
const readingStartedField = 'readingStarted';

MetaEdit readingStartedEdit(bool? on, {required DateTime at}) =>
    on == null ? MetaEdit.undo(at: at) : MetaEdit(on ? '1' : '0', at: at);

bool? readingStartedMark(String? raw) {
  if (raw == null) return null;
  final e = MetaEdit.decode(raw);
  return e.fromFile ? null : e.value == '1';
}

/// A people list as typed: comma-separated, trimmed, blanks dropped.
List<String> splitPeople(String? s) =>
    s?.split(',').map((w) => w.trim()).where((w) => w.isNotEmpty).toList() ?? const [];

/// The `field` of the overrides row recording that a large model drew the
/// comic's panels (tool/llm_panels.py writes it into the sidecar with the
/// panels; docs/llm-panels.md). Its [MetaEdit] value is JSON,
/// `{"runs": [{"harness", "model", "prompt", "pages", "at"}, ...]}`, oldest
/// run first. An overrides row for the same reasons as [completedField]:
/// the app keeps and merges it by content key and time without knowing it,
/// and it travels in the sidecar and a settings export. Redo panels drops it
/// with the panels; [activeEdits] leaves it out.
const panelImportField = 'panelImport';

/// One import of panels drawn by a large model, as [panelImportField] holds it.
class PanelImportRun {
  const PanelImportRun({
    required this.harness,
    required this.model,
    required this.prompt,
    required this.pages,
    this.at,
  });

  /// What ran the model ("Claude Code", "Codex") and the model's name.
  final String harness;
  final String model;

  /// The version of the tool's drawing rules (PROMPT_VERSION in the tool).
  final int prompt;

  /// The pages it drew, from 1, as ranges: "1-12, 15".
  final String pages;
  final DateTime? at;

  /// The runs in the overrides row [raw], oldest first; none for no row, an
  /// undone one, or one that does not read.
  static List<PanelImportRun> decodeAll(String? raw) {
    if (raw == null) return const [];
    final edit = MetaEdit.decode(raw);
    if (edit.fromFile || edit.value == null) return const [];
    try {
      if (jsonDecode(edit.value!) case {'runs': final List<Object?> runs}) {
        return [
          for (final r in runs.whereType<Map<String, Object?>>())
            PanelImportRun(
              harness: r['harness'] is String ? r['harness']! as String : 'unknown',
              model: r['model'] is String ? r['model']! as String : 'unknown',
              prompt: r['prompt'] is int ? r['prompt']! as int : 0,
              pages: r['pages'] is String ? r['pages']! as String : '',
              at: r['at'] is int ? DateTime.fromMillisecondsSinceEpoch(r['at']! as int) : null,
            ),
        ];
      }
    } on FormatException {
      // Not JSON: no runs.
    }
    return const [];
  }
}

/// The `field` of the overrides row that says when the comic's reading
/// status was cleared (`gR`, Clear the Reading list): every device's
/// position saved before that time no longer counts, so the comic leaves
/// the Reading tab on every device its sidecar reaches. An overrides row,
/// for the reasons [completedField] gives; [activeEdits] leaves it out.
const readingClearedField = 'readingCleared';

/// When the overrides row [raw] of [readingClearedField] says the reading
/// status was cleared; null for no row.
DateTime? readingClearedAt(String? raw) => raw == null ? null : MetaEdit.decode(raw).at;
