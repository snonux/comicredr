import 'dart:io';

import 'package:reader_input/reader_input.dart';
import 'package:test/test.dart';

List<String> keysFor(Keymap m, ReaderIntent intent) => [
  for (final b in m.bindings.where((b) => b.intent == intent)) Keymap.describe(b),
];

void main() {
  group('parseKeySpec', () {
    test('reads sequences, named keys, Ctrl and mark slots', () {
      expect(parseKeySpec('gg'), ['g', 'g']);
      expect(parseKeySpec('C-f'), ['C-f']);
      expect(parseKeySpec('S-Tab'), ['S-Tab']);
      expect(parseKeySpec('PageDown'), ['PageDown']);
      expect(parseKeySpec('g Home'), ['g', 'Home']);
      expect(parseKeySpec('m<a-z>'), ['m', letterSlot]);
      expect(parseKeySpec("''"), ["'", "'"]);
      expect(parseKeySpec('?'), ['?']);
    });

    test('refuses a misspelt key name rather than typing its letters', () {
      expect(parseKeySpec('Pagedown'), isNull);
      for (final typo in ['ESC', 'LEFT', 'PgDn', 'BackSpace', 'F13', 'pagedown']) {
        expect(parseKeySpec(typo), isNull, reason: typo);
      }
      // Letters typed one after another stay allowed.
      expect(parseKeySpec('ZZ'), ['Z', 'Z']);
      expect(parseKeySpec('gg'), ['g', 'g']);
      expect(parseKeySpec('F1'), ['F1']);
      expect(parseKeySpec('S-x'), isNull);
      expect(parseKeySpec(''), isNull);
    });
  });

  group('keymapFromToml', () {
    test('an action listed replaces its keys, the rest keep theirs', () {
      final load = keymapFromToml('''
# my keys
[keys]
autoTrim = "U"
nextStep = [
  "Space",   # just the space bar
  "x",
]
''');
      expect(load.warnings, isEmpty);
      expect(keysFor(load.keymap, ReaderIntent.autoTrim), ['U']);
      expect(keysFor(load.keymap, ReaderIntent.nextStep), ['Space', 'x']);
      expect(keysFor(load.keymap, ReaderIntent.prevStep), ['h', 'Left', 'S-Space']);
    });

    test('a key given to another action leaves its default one', () {
      final load = keymapFromToml('[keys]\nnightFilter = "t"\n');
      expect(keysFor(load.keymap, ReaderIntent.nightFilter), ['t']);
      expect(keysFor(load.keymap, ReaderIntent.autoTrim), isEmpty);
      final r = KeySequenceResolver(load.keymap);
      expect(r.feed('t', DateTime(2026))?.intent, ReaderIntent.nightFilter);
    });

    test('[] unbinds an action', () {
      final load = keymapFromToml("[keys]\nfullscreen = []\n");
      expect(keysFor(load.keymap, ReaderIntent.fullscreen), isEmpty);
    });

    test('bad lines are named and skipped, good ones still apply', () {
      final load = keymapFromToml('''
[keys]
nopeAction = "q"
autoTrim = ["Pagedown", "U"]
zoomIn = "5"
setMark = "M"
''');
      expect(keysFor(load.keymap, ReaderIntent.autoTrim), ['U']);
      expect(keysFor(load.keymap, ReaderIntent.zoomIn), isEmpty);
      expect(load.warnings, hasLength(4));
      expect(load.warnings.join('\n'), allOf(contains('nopeAction'), contains('Pagedown'), contains('digit')));
    });

    test('a broken file falls back to the defaults and says why', () {
      final load = keymapFromToml('[keys]\nautoTrim = "T\n');
      expect(load.warnings.single, contains('line 2'));
      expect(load.keymap.bindings.length, Keymap.defaults().bindings.length);
    });

    test('warns when a short key hides a longer one', () {
      final load = keymapFromToml('[keys]\nautoTrim = "g"\n');
      expect(load.warnings, [
        contains('hides gg'),
        contains('hides gw'),
        contains('hides gr'),
        contains('hides gf'),
        contains('hides gs'),
        contains('hides gd'),
        contains('hides gt'),
      ]);
    });

    test('mark keys need their letter slot', () {
      final load = keymapFromToml('[keys]\nsetMark = "Q<a-z>"\njumpMark = "`<a-z>"\n');
      expect(load.warnings, isEmpty);
      final r = KeySequenceResolver(load.keymap);
      expect(r.feed('Q', DateTime(2026)), isNull);
      expect(r.feed('q', DateTime(2026)), const ReaderCommand(ReaderIntent.setMark, register: 'q'));
    });
  });

  test('the written defaults read back as the same keymap', () {
    final defaults = Keymap.defaults();
    final load = keymapFromToml(keymapToToml(defaults));
    expect(load.warnings, isEmpty);
    List<String> spelled(Keymap m) =>
        [for (final b in m.bindings) '${b.intent.name} ${b.keys.join(' ')} ${b.layer.name}']..sort();
    expect(spelled(load.keymap), spelled(defaults));
  });

  test('docs/keys.toml is the current default keymap', () {
    // Regenerate with: dart run packages/reader_input/tool/write_keys_toml.dart
    final file = File('../../docs/keys.toml');
    expect(file.readAsStringSync(), keymapToToml(Keymap.defaults()));
  });
}
