import 'package:reader_input/reader_input.dart';
import 'package:test/test.dart';

void main() {
  const back = ReaderIntent.prevStep, next = ReaderIntent.nextStep, status = ReaderIntent.fullscreen;

  test('zones: 30% side columns and thirds for rows', () {
    expect(TouchZone.at(0.1, 0.5), TouchZone.left);
    expect(TouchZone.at(0.29, 0.1), TouchZone.topLeft);
    expect(TouchZone.at(0.5, 0.5), TouchZone.middle);
    expect(TouchZone.at(0.71, 0.9), TouchZone.bottomRight);
    expect(TouchZone.at(0.5, 0.2), TouchZone.top);
  });

  test('the standard preset is the touch layout the reader always had', () {
    final m = TouchMap.preset(TouchPreset.standard);
    for (final z in TouchZone.values) {
      expect(m.action(TouchGesture.tap, z), [back, status, next][z.column]);
      expect(m.waitsForDoubleTap(z), z.column == 1);
    }
    expect(m.action(TouchGesture.doubleTap, TouchZone.middle), ReaderIntent.zoomToggle);
    expect(m.action(TouchGesture.swipeLeft), next);
    expect(m.action(TouchGesture.swipeRight), back);
    expect(m.action(TouchGesture.swipeUp), isNull);
    expect(m.action(TouchGesture.longPress, TouchZone.middle), ReaderIntent.showTime);
    expect(m.action(TouchGesture.longPress, TouchZone.topLeft), isNull);
    expect(m.action(TouchGesture.twoFingerTap), isNull);
  });

  test('left-handed mirrors the edges, one thumb goes on almost everywhere', () {
    final l = TouchMap.preset(TouchPreset.leftHanded);
    expect(l.action(TouchGesture.tap, TouchZone.left), next);
    expect(l.action(TouchGesture.tap, TouchZone.bottomRight), back);
    final o = TouchMap.preset(TouchPreset.oneThumb);
    expect(o.actions(TouchGesture.tap), [back, back, back, next, status, next, next, next, next]);
    expect(TouchPreset.byName('oneThumb'), TouchPreset.oneThumb);
    expect(TouchPreset.byName('nope'), TouchPreset.standard);
  });

  group('[touch] in keys.toml', () {
    test('a grid, a single action and "" each set their gesture', () {
      final load = keymapFromToml('''
[touch]
tap = [
  "nextStep", "fullscreen", "nextStep",
  "prevStep", "", "nextStep",
  "prevStep", "bookmark", "none",
]
longPress = "showKeymap"
twoFingerTap = "toggleGuided"
swipeLeft = ""
''');
      expect(load.warnings, isEmpty);
      final m = TouchMap.preset(TouchPreset.standard).withOverrides(load.touch);
      expect(m.action(TouchGesture.tap, TouchZone.topLeft), next);
      expect(m.action(TouchGesture.tap, TouchZone.middle), isNull);
      expect(m.action(TouchGesture.tap, TouchZone.bottom), ReaderIntent.bookmark);
      expect(m.action(TouchGesture.tap, TouchZone.bottomRight), isNull);
      for (final z in TouchZone.values) {
        expect(m.action(TouchGesture.longPress, z), ReaderIntent.showKeymap);
      }
      expect(m.action(TouchGesture.twoFingerTap), ReaderIntent.toggleGuided);
      expect(m.action(TouchGesture.swipeLeft), isNull);
      // Not listed: the preset's.
      expect(m.action(TouchGesture.swipeRight), back);
      expect(m.action(TouchGesture.doubleTap, TouchZone.middle), ReaderIntent.zoomToggle);
      // Keys are untouched.
      expect(load.keymap.bindings.length, Keymap.defaults().bindings.length);
    });

    test('lines laid over the left-handed preset keep the rest of it', () {
      final load = keymapFromToml('[touch]\ntwoFingerTap = "bookmark"\n');
      final m = TouchMap.preset(TouchPreset.leftHanded).withOverrides(load.touch);
      expect(m.action(TouchGesture.tap, TouchZone.left), next);
      expect(m.action(TouchGesture.twoFingerTap), ReaderIntent.bookmark);
    });

    test('bad lines are named and skipped like bad key lines', () {
      final load = keymapFromToml('''
[keys]
autoTrim = "U"
[touch]
pinch = "zoomIn"
tap = ["nextStep", "prevStep"]
swipeUp = ["nextStep"]
longPress = "nextStpe"
twoFingerTap = "bookmark"
''');
      expect(load.warnings, hasLength(4));
      final all = load.warnings.join('\n');
      expect(all, allOf(contains('"pinch"'), contains('nine actions'), contains('one action'), contains('"nextStpe"')));
      expect(load.warnings.every((w) => w.startsWith('keys.toml: [touch]')), isTrue);
      expect(load.touch.keys, [TouchGesture.twoFingerTap]);
      expect(load.keymap.bindings.where((b) => b.intent == ReaderIntent.autoTrim).single.keys, ['U']);
    });

    test('other tables are still refused', () {
      final load = keymapFromToml('[mouse]\nx = "y"\n');
      expect(load.warnings.single, contains('only [keys] and [touch]'));
    });

    test('the written [touch] section, uncommented, reads back as the standard preset', () {
      final text = touchMapToToml(TouchMap.preset(TouchPreset.standard));
      final uncommented = text
          .split('\n')
          .map((l) {
            final m = RegExp(r'^# (\s*("|[a-zA-Z]+ =|\]))').firstMatch(l);
            return m == null ? l : l.substring(2);
          })
          .join('\n');
      final load = keymapFromToml(uncommented);
      expect(load.warnings, isEmpty);
      expect(load.touch.keys.toSet(), TouchGesture.values.toSet());
      expect(TouchMap.preset(TouchPreset.leftHanded).withOverrides(load.touch), TouchMap.preset(TouchPreset.standard));
    });
  });
}
