import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import 'reader_providers.dart';

/// How often a held arrow key moves the page on by a step, whatever the
/// smoothness: with the step it sets how fast a held key scrolls.
const heldStepSeconds = 0.07;

/// How fast the arrow keys and `j` `k` scroll a zoomed page: how far one
/// press goes, as a share of the screen. A held key goes a step every
/// [heldStepSeconds], so this sets its speed too.
enum ScrollSpeed {
  slowest('Slowest', 0.08),
  slow('Slow', 0.11),
  normal('Normal', 0.15),
  fast('Fast', 0.2),
  fastest('Fastest', 0.27);

  const ScrollSpeed(this.label, this.step);

  final String label;

  /// One press, as a share of the screen's height (or width, sideways).
  final double step;

  static ScrollSpeed byName(String? name) => values.firstWhere((s) => s.name == name, orElse: () => ScrollSpeed.normal);

  /// One notch faster ([by] 1) or slower (-1), stopping at the ends.
  ScrollSpeed notch(int by) => values[(index + by).clamp(0, values.length - 1)];
}

/// The scrolling speed picked in Settings or with `g+` `g-`, kept in the
/// settings table.
final scrollSpeedProvider = NotifierProvider<ScrollSpeedNotifier, ScrollSpeed>(ScrollSpeedNotifier.new);

class ScrollSpeedNotifier extends Notifier<ScrollSpeed> {
  bool _picked = false;

  @override
  ScrollSpeed build() {
    unawaited(_load());
    return ScrollSpeed.normal;
  }

  Future<void> _load() async {
    try {
      final name = await ref.read(settingsStoreProvider).loadString(SettingsStore.scrollSpeed);
      if (!_picked && ref.mounted) state = ScrollSpeed.byName(name);
    } catch (_) {
      // No settings yet: normal.
    }
  }

  /// Takes up the saved speed again, after an import changed it.
  Future<void> reload() async {
    _picked = false;
    await _load();
  }

  Future<void> pick(ScrollSpeed speed) async {
    _picked = true;
    state = speed;
    await ref.read(settingsStoreProvider).saveString(SettingsStore.scrollSpeed, speed.name);
  }
}

/// How softly a key glide starts and stops: the time a press takes to get
/// most of the way (95%). The page speeds up and slows down gently along a
/// critically damped spring, so it never overshoots. It doesn't change how
/// far a press goes or how fast a held key scrolls.
enum ScrollSmoothness {
  crisp('Crisp', 0.15),
  light('Light', 0.22),
  smooth('Smooth', 0.3),
  smoother('Smoother', 0.4),
  smoothest('Smoothest', 0.55);

  const ScrollSmoothness(this.label, this.seconds);

  final String label;

  /// About how long one press takes.
  final double seconds;

  /// The spring's natural frequency: a critically damped spring covers 95%
  /// of the way in 4.74 of its time units.
  double get stiffness => 4.74 / seconds;

  static ScrollSmoothness byName(String? name) =>
      values.firstWhere((s) => s.name == name, orElse: () => ScrollSmoothness.smooth);

  /// One notch smoother ([by] 1) or crisper (-1), stopping at the ends.
  ScrollSmoothness notch(int by) => values[(index + by).clamp(0, values.length - 1)];
}

/// The smoothness picked in Settings or with `g>` `g<`, kept in the
/// settings table.
final scrollSmoothnessProvider = NotifierProvider<ScrollSmoothnessNotifier, ScrollSmoothness>(
  ScrollSmoothnessNotifier.new,
);

class ScrollSmoothnessNotifier extends Notifier<ScrollSmoothness> {
  bool _picked = false;

  @override
  ScrollSmoothness build() {
    unawaited(_load());
    return ScrollSmoothness.smooth;
  }

  Future<void> _load() async {
    try {
      final name = await ref.read(settingsStoreProvider).loadString(SettingsStore.scrollSmoothness);
      if (!_picked && ref.mounted) state = ScrollSmoothness.byName(name);
    } catch (_) {
      // No settings yet: smooth.
    }
  }

  /// Takes up the saved smoothness again, after an import changed it.
  Future<void> reload() async {
    _picked = false;
    await _load();
  }

  Future<void> pick(ScrollSmoothness smoothness) async {
    _picked = true;
    state = smoothness;
    await ref.read(settingsStoreProvider).saveString(SettingsStore.scrollSmoothness, smoothness.name);
  }
}
