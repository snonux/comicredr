import 'intents.dart';

/// The reader is split into a 3x3 grid for taps, double-taps and long
/// presses. The side columns are 30% of the width each, as the edge taps
/// always were; the rows are thirds.
enum TouchZone {
  topLeft,
  top,
  topRight,
  left,
  middle,
  right,
  bottomLeft,
  bottom,
  bottomRight;

  static const edge = 0.3;

  /// The zone a point falls in, given as shares (0 to 1) of the view.
  static TouchZone at(double x, double y) {
    final col = x < edge ? 0 : (x > 1 - edge ? 2 : 1);
    final row = y < 1 / 3 ? 0 : (y > 2 / 3 ? 2 : 1);
    return TouchZone.values[row * 3 + col];
  }

  int get row => index ~/ 3;
  int get column => index % 3;
}

/// The gestures a `[touch]` line can set. The first three take a grid of
/// nine actions (or one action for the whole view); the rest take one.
enum TouchGesture {
  tap('Tap'),
  doubleTap('Double-tap'),
  longPress('Long press'),
  swipeLeft('Swipe left'),
  swipeRight('Swipe right'),
  swipeUp('Swipe up'),
  swipeDown('Swipe down'),
  twoFingerTap('Two-finger tap');

  const TouchGesture(this.label);

  final String label;

  bool get zoned => index <= longPress.index;
}

/// Ready-made touch layouts, picked in Settings. A `[touch]` section in
/// `keys.toml` changes single gestures on top of the one picked.
enum TouchPreset {
  standard('Standard', 'Tap the left edge to go back, the right edge to go on, the middle for the status line'),
  leftHanded('Left-handed', 'Mirrored for the left thumb: the left edge goes on, the right edge goes back'),
  oneThumb('One thumb', 'Tap almost anywhere to go on; the top row goes back');

  const TouchPreset(this.label, this.description);

  final String label;
  final String description;

  /// Settings stores the name; an unknown one reads as [standard].
  static TouchPreset byName(String? name) => values.asNameMap()[name] ?? standard;
}

/// What each gesture on the reader does. Grids are row-major, top-left
/// first; null means the gesture does nothing there.
class TouchMap {
  TouchMap(Map<TouchGesture, List<ReaderIntent?>> actions)
    : _actions = {
        for (final g in TouchGesture.values)
          g: List.unmodifiable(actions[g] ?? List<ReaderIntent?>.filled(g.zoned ? 9 : 1, null)),
      } {
    for (final MapEntry(key: g, value: a) in _actions.entries) {
      if (a.length != (g.zoned ? 9 : 1)) throw ArgumentError('${g.name} needs ${g.zoned ? 9 : 1} actions');
    }
  }

  final Map<TouchGesture, List<ReaderIntent?>> _actions;

  factory TouchMap.preset(TouchPreset preset) {
    const back = ReaderIntent.prevStep, next = ReaderIntent.nextStep, status = ReaderIntent.fullscreen;
    const zoom = ReaderIntent.zoomToggle;
    // Double-tap only where it has always worked, the middle column, so the
    // edges turn pages at once rather than waiting to see if a second tap
    // follows.
    const doubleTap = [null, zoom, null, null, zoom, null, null, zoom, null];
    const swipes = {
      TouchGesture.swipeLeft: [next],
      TouchGesture.swipeRight: [back],
    };
    return TouchMap({
      TouchGesture.tap: switch (preset) {
        TouchPreset.standard => const [back, status, next, back, status, next, back, status, next],
        TouchPreset.leftHanded => const [next, status, back, next, status, back, next, status, back],
        TouchPreset.oneThumb => const [back, back, back, next, status, next, next, next, next],
      },
      TouchGesture.doubleTap: doubleTap,
      ...swipes,
    });
  }

  /// The action for a zoned gesture in [zone], or for any other gesture.
  ReaderIntent? action(TouchGesture g, [TouchZone zone = TouchZone.topLeft]) => _actions[g]![g.zoned ? zone.index : 0];

  List<ReaderIntent?> actions(TouchGesture g) => _actions[g]!;

  /// Whether a double-tap does anything in [zone]. Where it doesn't, a tap
  /// acts at once instead of waiting for a second one.
  bool waitsForDoubleTap(TouchZone zone) => action(TouchGesture.doubleTap, zone) != null;

  /// This map with the gestures in [overrides] replaced.
  TouchMap withOverrides(Map<TouchGesture, List<ReaderIntent?>> overrides) =>
      overrides.isEmpty ? this : TouchMap({..._actions, ...overrides});

  @override
  bool operator ==(Object other) =>
      other is TouchMap &&
      TouchGesture.values.every((g) {
        final a = _actions[g]!, b = other._actions[g]!;
        return Iterable.generate(a.length).every((i) => a[i] == b[i]);
      });

  @override
  int get hashCode => Object.hashAll(TouchGesture.values.expand((g) => _actions[g]!));
}

/// Reads one `[touch]` line's value: an action name, `""` for nothing, or
/// for a zoned gesture a list of nine. Adds what is wrong to [warnings] and
/// returns null when the line cannot be used.
List<ReaderIntent?>? parseTouchLine(TouchGesture g, Object value, List<String> warnings) {
  final byName = ReaderIntent.values.asNameMap();
  final where = 'keys.toml: [touch] ${g.name}';
  ReaderIntent? read(String name, List<String> bad) {
    final n = name.trim();
    if (n.isEmpty || n == 'none') return null;
    final intent = byName[n];
    if (intent == null) bad.add(n);
    return intent;
  }

  final bad = <String>[];
  final List<ReaderIntent?> out;
  if (value is String) {
    final one = read(value, bad);
    out = List.filled(g.zoned ? 9 : 1, one);
  } else {
    final list = (value as List).cast<String>();
    if (!g.zoned) {
      warnings.add('$where: takes one action, not a list');
      return null;
    }
    if (list.length != 9) {
      warnings.add('$where: needs nine actions, one per zone, top-left first (got ${list.length})');
      return null;
    }
    out = [for (final name in list) read(name, bad)];
  }
  if (bad.isNotEmpty) {
    warnings.add('$where: no action called ${bad.map((b) => '"$b"').join(', ')}');
    return null;
  }
  return out;
}

/// The `[touch]` section of the written-out `keys.toml`: every line of
/// the standard preset, commented out, since a line left in would override
/// the preset picked in Settings.
String touchMapToToml(TouchMap map) {
  String name(ReaderIntent? i) => '"${i?.name ?? ''}"';
  final out = StringBuffer()
    ..writeln('[touch]')
    ..writeln('# Touch gestures, on top of the preset picked in Settings (Standard,')
    ..writeln('# Left-handed or One thumb). Uncomment a line to change that gesture.')
    ..writeln('# Taps, double-taps and long presses take nine actions, one per zone')
    ..writeln('# of a 3x3 grid read like a page: top row first, left to right. The')
    ..writeln('# side columns are 30% of the width each. One action instead of a')
    ..writeln('# list sets the whole view; "" does nothing. Actions are the names in')
    ..writeln('# [keys] above. Pinch zoom and dragging a zoomed page always work.')
    ..writeln('# gt shows the zones while reading.');
  for (final g in TouchGesture.values) {
    final a = map.actions(g);
    out.writeln('#');
    if (!g.zoned) {
      out.writeln('# ${g.name} = ${name(a.first)}');
    } else if (a.every((i) => i == null)) {
      out.writeln('# ${g.name} = ""');
    } else {
      out.writeln('# ${g.name} = [');
      for (var r = 0; r < 3; r++) {
        out.writeln('#   ${[for (var c = 0; c < 3; c++) name(a[r * 3 + c])].join(', ')},');
      }
      out.writeln('# ]');
    }
  }
  return out.toString();
}
