import 'intents.dart';
import 'keymap.dart';
import 'touch_map.dart';

/// Named keys a binding may use, as `reader_input` tokens spell them.
const namedKeys = {
  'Left', 'Right', 'Up', 'Down', 'PageUp', 'PageDown', 'Home', 'End', //
  'Space', 'Tab', 'Esc', 'Enter', 'Backspace', 'Delete', 'Insert',
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
};

/// A keymap read from `keys.toml`, with what was wrong in the file. A
/// line that cannot be used is skipped and named here; the rest still
/// applies, so one typo never costs the whole keymap.
class KeymapLoad {
  const KeymapLoad(this.keymap, this.warnings, {this.touch = const {}});

  final Keymap keymap;
  final List<String> warnings;

  /// The gestures the `[touch]` section sets, to lay over the touch preset
  /// picked in Settings. Gestures not listed keep the preset's.
  final Map<TouchGesture, List<ReaderIntent?>> touch;
}

/// Reads a `keys.toml` over [base] (the defaults when left out).
///
/// ```toml
/// [keys]
/// nextStep = ["l", "Right", "Space"]   # replaces all of nextStep's keys
/// autoTrim = "T"                       # one key needs no list
/// fullscreen = []                      # unbinds it
///
/// [touch]
/// tap = [
///   "prevStep", "fullscreen", "nextStep",
///   "prevStep", "fullscreen", "nextStep",
///   "prevStep", "bookmark",   "nextStep",
/// ]
/// longPress = "showKeymap"             # one action for the whole view
/// twoFingerTap = "toggleGuided"
/// ```
///
/// Each action named replaces all of its default keys; actions not named
/// keep theirs. A key taken for one action is taken off whatever the
/// defaults gave it to. Keys are spelled as in the `?` overlay: `gg` and
/// `zw` for sequences, `m<a-z>` for a mark letter, `C-f` for Ctrl, named
/// keys like `PageDown` or `S-Tab` alone or separated by spaces (`g Home`).
KeymapLoad keymapFromToml(String text, {Keymap? base}) {
  base ??= Keymap.defaults();
  final warnings = <String>[];
  final Map<String, Object> table;
  final Map<String, Object> touchTable;
  try {
    final tables = _parseToml(text, warnings);
    table = tables['keys'] ?? const {};
    touchTable = tables['touch'] ?? const {};
  } on FormatException catch (e) {
    return KeymapLoad(base, ['keys.toml: ${e.message}; using the default keys and touch']);
  }
  final gestures = TouchGesture.values.asNameMap();
  final touch = <TouchGesture, List<ReaderIntent?>>{};
  for (final MapEntry(key: name, value: value) in touchTable.entries) {
    final g = gestures[name];
    if (g == null) {
      warnings.add('keys.toml: [touch] has no gesture called "$name"');
      continue;
    }
    if (parseTouchLine(g, value, warnings) case final actions?) touch[g] = actions;
  }
  final byName = ReaderIntent.values.asNameMap();
  final replaced = <ReaderIntent, List<Binding>>{};
  for (final MapEntry(key: name, value: value) in table.entries) {
    final intent = byName[name];
    if (intent == null) {
      warnings.add('keys.toml: no action called "$name"');
      continue;
    }
    final specs = value is List ? value.cast<String>() : [value as String];
    final bindings = <Binding>[];
    for (final spec in specs) {
      final keys = parseKeySpec(spec);
      if (keys == null) {
        warnings.add('keys.toml: $name: cannot read the key "$spec"');
      } else if (_isCountDigit(keys.first)) {
        warnings.add('keys.toml: $name: "$spec" starts with a digit, which types a count');
      } else if (intent == ReaderIntent.setMark || intent == ReaderIntent.jumpMark
          ? keys.where((k) => k == letterSlot).length != 1
          : keys.contains(letterSlot)) {
        warnings.add(
          'keys.toml: $name: "$spec" ${keys.contains(letterSlot) ? 'needs exactly one' : 'cannot take a'} <a-z>',
        );
      } else {
        bindings.add(Binding(keys, intent, layer: _layerOf(intent, keys, base)));
      }
    }
    replaced[intent] = bindings;
  }

  final taken = {for (final b in replaced.values.expand((b) => b)) b.keys.join('\u0000')};
  final out = <Binding>[];
  final placed = <ReaderIntent>{};
  for (final b in base.bindings) {
    final mine = replaced[b.intent];
    if (mine == null) {
      // A default key someone gave to another action goes with it.
      if (!taken.contains(b.keys.join('\u0000'))) out.add(b);
    } else if (placed.add(b.intent)) {
      out.addAll(mine); // In the defaults' place, so the overlay keeps its order.
    }
  }
  for (final MapEntry(key: intent, value: mine) in replaced.entries) {
    if (placed.add(intent)) out.addAll(mine);
  }

  // A key that is the start of a longer one makes the longer one untypable,
  // since the short one fires first.
  for (final a in out) {
    for (final b in out) {
      if (b.keys.length > a.keys.length && _startsWith(b.keys, a.keys)) {
        warnings.add(
          'keys.toml: ${Keymap.describe(a)} (${a.intent.name}) hides ${Keymap.describe(b)} (${b.intent.name})',
        );
      }
    }
  }
  return KeymapLoad(Keymap(out), warnings, touch: touch);
}

/// Turns a key spelling (`gg`, `C-f`, `m<a-z>`, `g Home`, `S-Tab`) into
/// tokens, or null when it cannot be read.
List<String>? parseKeySpec(String spec) {
  final chunks = spec.trim().split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();
  if (chunks.isEmpty) return null;
  final keys = <String>[];
  for (final chunk in chunks) {
    final named = RegExp(r'^(C-)?(S-)?(.+)$').firstMatch(chunk)!;
    final ctrl = named.group(1) != null;
    final shift = named.group(2) != null;
    final rest = named.group(3)!;
    if (namedKeys.contains(rest)) {
      keys.add(chunk);
    } else if (ctrl && !shift && rest.length == 1 && RegExp(r'[a-z0-9\[\]]').hasMatch(rest)) {
      keys.add('C-$rest');
    } else if (ctrl || shift) {
      return null; // C- or S- on something that is not a key.
    } else if (_misspeltName(chunk)) {
      return null; // A misspelt key name, not the keys P, a, g, e...
    } else {
      // Printable keys typed one after another: `gg`, `zw`, `m<a-z>`.
      var rest = chunk;
      while (rest.isNotEmpty) {
        final slot = ['<a-z>', letterSlot].where(rest.startsWith).firstOrNull;
        final key = slot ?? String.fromCharCode(rest.runes.first);
        keys.add(slot != null ? letterSlot : key);
        rest = rest.substring(key.length);
      }
    }
  }
  return keys;
}

/// The default keymap written out as a `keys.toml`, one line per action
/// with its description, for people to copy and edit.
String keymapToToml(Keymap keymap) {
  final byIntent = <ReaderIntent, List<Binding>>{};
  for (final b in keymap.bindings) {
    byIntent.putIfAbsent(b.intent, () => []).add(b);
  }
  final out = StringBuffer()
    ..writeln('# ComicRedr keys. Copy this file to ~/.config/comicredr/keys.toml,')
    ..writeln('# or ~/Comics/.comicredr/keys.toml when ComicRedr keeps its data there')
    ..writeln('# (? says where; on the phone: Android/data/org.snonux.comicredr/files/keys.toml)')
    ..writeln('# and keep only the lines you change: an action listed here replaces')
    ..writeln('# all of its default keys, [] unbinds it, and actions left out keep')
    ..writeln('# their defaults. Restart ComicRedr to load it; ? shows what is live.')
    ..writeln('#')
    ..writeln('# Spelling: gg and zw are two keys in a row, m<a-z> takes a mark')
    ..writeln('# letter, C-f is Ctrl+f, and named keys (Left Right Up Down PageUp')
    ..writeln('# PageDown Home End Space Tab Esc Enter Backspace Delete Insert F1-F12)')
    ..writeln('# take S- for Shift. Put spaces between keys when a named key is in')
    ..writeln('# a sequence: "g Home".')
    ..writeln()
    ..writeln('[keys]');
  for (final intent in ReaderIntent.values) {
    final bindings = byIntent[intent] ?? const [];
    out
      ..writeln('# ${intent.description}')
      ..writeln('${intent.name} = [${bindings.map((b) => _quote(Keymap.describe(b))).join(', ')}]');
  }
  out
    ..writeln()
    ..write(touchMapToToml(TouchMap.preset(TouchPreset.standard)));
  return out.toString();
}

String _quote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

bool _isCountDigit(String t) => t.length == 1 && '123456789'.contains(t);

bool _startsWith(List<String> long, List<String> short) {
  for (var i = 0; i < short.length; i++) {
    final a = long[i], b = short[i];
    if (a != b && !(b == letterSlot && a.length == 1) && !(a == letterSlot && b.length == 1)) return false;
  }
  return true;
}

/// Where a new binding shows in the overlay: with the default it copies,
/// else standard for named keys and vi for the rest.
Layer _layerOf(ReaderIntent intent, List<String> keys, Keymap base) {
  for (final b in base.bindings) {
    if (b.intent == intent && b.keys.join() == keys.join()) return b.layer;
  }
  return keys.every((k) => namedKeys.contains(k.replaceFirst('C-', '').replaceFirst('S-', '')))
      ? Layer.standard
      : Layer.vi;
}

/// The small part of TOML a keys file needs: comments, the `[keys]` and
/// `[touch]` tables, and `name = "string"` or `name = ["string", ...]`
/// (lists may span lines). Basic and literal strings are both read.
Map<String, Map<String, Object>> _parseToml(String text, List<String> warnings) {
  const known = {'keys', 'touch'};
  final out = <String, Map<String, Object>>{};
  // A byte-order mark, as some editors save UTF-8, is not text.
  var i = text.startsWith('\uFEFF') ? 1 : 0;
  var line = 1;
  String? table;

  Never fail(String what) => throw FormatException('line $line: $what');

  void skipSpace({bool newlines = false}) {
    while (i < text.length) {
      final c = text[i];
      if (c == ' ' || c == '\t' || c == '\r') {
        i++;
      } else if (c == '#') {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
      } else if (c == '\n' && newlines) {
        i++;
        line++;
      } else {
        break;
      }
    }
  }

  String readString() {
    final quote = text[i++];
    final sb = StringBuffer();
    while (true) {
      if (i >= text.length || text[i] == '\n') fail('a string is not closed');
      final c = text[i++];
      if (c == quote) return sb.toString();
      if (c == r'\' && quote == '"') {
        if (i >= text.length) fail('a string is not closed');
        final e = text[i++];
        switch (e) {
          case 'n':
            sb.write('\n');
          case 't':
            sb.write('\t');
          case '"':
          case r'\':
            sb.write(e);
          case 'u':
            if (i + 4 > text.length) fail('bad \\u escape');
            final code = int.tryParse(text.substring(i, i + 4), radix: 16) ?? fail('bad \\u escape');
            sb.writeCharCode(code);
            i += 4;
          default:
            fail('unknown escape \\$e');
        }
      } else {
        sb.write(c);
      }
    }
  }

  Object readValue() {
    if (i < text.length && (text[i] == '"' || text[i] == "'")) return readString();
    if (i < text.length && text[i] == '[') {
      i++;
      final items = <String>[];
      while (true) {
        skipSpace(newlines: true);
        if (i >= text.length) fail('a list is not closed');
        if (text[i] == ']') {
          i++;
          return items;
        }
        if (text[i] != '"' && text[i] != "'") fail('a list holds names in quotes');
        items.add(readString());
        skipSpace(newlines: true);
        if (i < text.length && text[i] == ',') {
          i++;
        } else if (i < text.length && text[i] != ']') {
          fail('expected , or ] in a list');
        }
      }
    }
    fail('expected a "key" or a ["list", "of", "keys"]');
  }

  while (true) {
    skipSpace(newlines: true);
    if (i >= text.length) break;
    if (text[i] == '[') {
      final end = text.indexOf(']', i);
      if (end < 0) fail('a [table] header is not closed');
      table = text.substring(i + 1, end).trim();
      if (!known.contains(table)) {
        warnings.add('keys.toml: ignoring the [$table] table; only [keys] and [touch] are read');
      }
      i = end + 1;
    } else {
      final String name;
      if (text[i] == '"' || text[i] == "'") {
        name = readString(); // TOML allows a quoted name: "nextStep" = "l".
      } else {
        final m = RegExp(r'[A-Za-z0-9_-]+').matchAsPrefix(text, i) ?? fail('expected an action or gesture name');
        name = m.group(0)!;
        i = m.end;
      }
      skipSpace();
      if (i >= text.length || text[i] != '=') fail('expected = after $name');
      i++;
      skipSpace();
      final value = readValue();
      if (known.contains(table)) {
        final t = out.putIfAbsent(table!, () => {});
        if (t.containsKey(name)) warnings.add('keys.toml: $name is listed twice; the last one counts');
        t[name] = value;
      } else if (table == null) {
        warnings.add('keys.toml: $name is outside [keys], so it is ignored');
      }
    }
    skipSpace();
    if (i < text.length && text[i] != '\n') fail('unexpected text after a value');
  }
  return out;
}

/// Whether [chunk] reads as a key name spelt wrong (`Pagedown`, `ESC`,
/// `LEFT`, `PgDn`, `BackSpace`, `F13`) rather than keys typed one after
/// another (`gg`, `zw`, `ZZ`), which would bind a string of letters and
/// leave the key it meant unbound.
bool _misspeltName(String chunk) {
  if (chunk.length < 2) return false;
  final lower = chunk.toLowerCase();
  if (namedKeys.any((n) => n.toLowerCase() == lower)) return true;
  if (RegExp(r'^F[0-9]+$').hasMatch(chunk)) return true;
  // A capital, then letters with at least one lowercase: a word.
  return RegExp(r'^[A-Z](?=[A-Za-z]*[a-z])[A-Za-z]+[0-9]*$').hasMatch(chunk);
}
