import 'intents.dart';
import 'keymap.dart';

/// One action in the `?` overlay: its keys as the overlay spells them.
typedef KeymapEntry = ({ReaderIntent intent, List<String> keys});

/// What a search of the `?` overlay found, best match first, or why the
/// query could not be used.
class KeymapSearch {
  const KeymapSearch(this.entries, {this.error});

  final List<KeymapEntry> entries;

  /// Set when a /regex/ does not compile; [entries] is then empty.
  final String? error;
}

/// The keymap as the overlay lists it: one entry per action, in the order
/// actions first appear in the keymap.
List<KeymapEntry> keymapEntries(Keymap keymap) {
  final byIntent = <ReaderIntent, List<String>>{};
  for (final b in keymap.bindings) {
    byIntent.putIfAbsent(b.intent, () => []).add(Keymap.describe(b));
  }
  return [for (final MapEntry(:key, :value) in byIntent.entries) (intent: key, keys: value)];
}

/// Filters the overlay to what [query] matches, over each action's keys,
/// its description and its `keys.toml` name.
///
/// A query between slashes is a case-insensitive regular expression
/// (`/^z/`). Anything else is fuzzy: every word must appear, either as it
/// is or with letters left out (`fulscr` finds fullscreen), and a word that
/// is exactly one of an action's keys (`gg`, `C-f`) puts that action first.
KeymapSearch searchKeymap(Keymap keymap, String query) {
  final all = keymapEntries(keymap);
  final q = query.trim();
  if (q.isEmpty) return KeymapSearch(all);
  String haystack(KeymapEntry e) => '${e.keys.join('  ')}  ${e.intent.description}  ${e.intent.name}';

  if (q.length >= 2 && q.startsWith('/') && q.endsWith('/')) {
    final RegExp re;
    try {
      re = RegExp(q.substring(1, q.length - 1), caseSensitive: false);
    } on FormatException catch (e) {
      return KeymapSearch(const [], error: 'Not a regex: ${e.message}');
    }
    return KeymapSearch([
      for (final e in all)
        if (re.hasMatch(haystack(e))) e,
    ]);
  }

  final terms = q.split(RegExp(r'\s+'));
  final scored = <(KeymapEntry, int)>[];
  for (final e in all) {
    final text = haystack(e).toLowerCase();
    var total = 0;
    for (final t in terms) {
      final s = e.keys.contains(t) ? 1000 : _score(text, t.toLowerCase());
      if (s == null) {
        total = -1;
        break;
      }
      total += s;
    }
    if (total >= 0) scored.add((e, total));
  }
  // Stable: equal scores keep the overlay's order.
  final order = {for (var i = 0; i < all.length; i++) all[i].intent: i};
  scored.sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : order[a.$1.intent]! - order[b.$1.intent]!);
  return KeymapSearch([for (final (e, _) in scored) e]);
}

/// How well [term] matches [text]: a whole-word start beats a substring,
/// which beats letters in order with small gaps. Null for no match.
int? _score(String text, String term) {
  final at = text.indexOf(term);
  if (at >= 0) {
    final wordStart = at == 0 || !_isWordChar(text.codeUnitAt(at - 1));
    return (wordStart ? 100 : 80) + term.length;
  }
  // Letters in order, each within a few characters of the one before, so
  // `fulscr` finds "fullscreen" but a word does not match scattered
  // letters across a whole sentence.
  var best = -1;
  for (var start = text.indexOf(term[0]); start >= 0; start = text.indexOf(term[0], start + 1)) {
    var pos = start;
    var gaps = 0;
    var ok = true;
    for (var k = 1; k < term.length; k++) {
      final next = text.indexOf(term[k], pos + 1);
      if (next < 0 || next - pos > 3) {
        ok = false;
        break;
      }
      gaps += next - pos - 1;
      pos = next;
    }
    if (ok) {
      final s = gaps < 49 ? 50 - gaps : 1;
      if (s > best) best = s;
    }
  }
  return best >= 0 && term.length >= 3 ? best : null;
}

bool _isWordChar(int c) => (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39);
