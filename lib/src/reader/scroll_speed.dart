import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import 'reader_providers.dart';

/// How fast the arrow keys and `j` `k` glide a zoomed page: how far one
/// press goes (a share of the screen) and how quickly the glide eases out
/// (its time constant). A held key moves about a step per time constant,
/// so the two together set its speed.
enum ScrollSpeed {
  slowest('Slowest', 0.08, 0.12),
  slow('Slow', 0.11, 0.095),
  normal('Normal', 0.15, 0.07),
  fast('Fast', 0.2, 0.055),
  fastest('Fastest', 0.27, 0.04);

  const ScrollSpeed(this.label, this.step, this.seconds);

  final String label;

  /// One press, as a share of the screen's height (or width, sideways).
  final double step;

  /// The glide's time constant: each frame covers the share of what is
  /// left that this much time would.
  final double seconds;

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
