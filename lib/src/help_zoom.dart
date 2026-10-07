import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/settings_store.dart';
import 'reader/reader_providers.dart';

/// How big the text of the `?` help is: a fixed row of steps, each a
/// factor on the usual text size. `+` and `-` (the zoomIn and zoomOut
/// intents), Ctrl and the wheel and a pinch go a step along it, `=` back to
/// [usual]. Steps and not any factor, so that a stored value, whatever it
/// says, always lands on a size that can be read and laid out.
abstract final class HelpZoom {
  /// The factors, smallest first. The largest is three times the usual
  /// text: 42 px letters, which the help still lays out (its two columns
  /// become one when the window is too narrow for both).
  static const scales = <double>[0.7, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0];

  /// The step of the usual size, factor 1.
  static const usual = 2;

  static const smallest = 0;
  static const largest = 9;

  /// [step] kept within the row.
  static int clamp(int step) => step.clamp(smallest, largest);

  /// The step whose factor is nearest [scale], which must be a finite
  /// number above zero: one beyond either end is that end. (Brought within
  /// the row first: from `1e300` every factor is equally far, as doubles
  /// go, and the nearest would have been the first, the smallest text.)
  static int nearest(double scale) {
    final within = scale.clamp(scales.first, scales.last);
    var best = smallest;
    for (var i = smallest + 1; i <= largest; i++) {
      if ((scales[i] - within).abs() < (scales[best] - within).abs()) best = i;
    }
    return best;
  }

  /// The step a stored setting stands for. Anything that is no size (not a
  /// number, `NaN`, zero, negative, infinite: [SettingsStore.parseSize]) is
  /// the usual size; a size off the row (a file written by hand) is the
  /// nearest step, so `1000000` is the largest text and not a blank screen.
  static int parse(String? stored) => switch (SettingsStore.parseSize(stored)) {
    null => usual,
    final scale => nearest(scale),
  };

  /// What is stored for [step]: its factor, and nothing at the usual size.
  static String? text(int step) => step == usual ? null : SettingsStore.sizeText(scales[step]);
}

/// The step of [HelpZoom.scales] the `?` help is shown at, kept as the
/// setting `help.textSize` across restarts. The app watches it from the
/// start, so the size is there by the time the help is first opened.
final helpZoomProvider = NotifierProvider<HelpZoomNotifier, int>(HelpZoomNotifier.new);

class HelpZoomNotifier extends Notifier<int> {
  /// A size was picked in this run: a slow first load must not undo it.
  bool _picked = false;

  @override
  int build() {
    unawaited(_load());
    return HelpZoom.usual;
  }

  Future<void> _load() async {
    try {
      final stored = await ref.read(settingsStoreProvider).loadString(SettingsStore.helpTextSize);
      if (!_picked && ref.mounted) state = HelpZoom.parse(stored);
    } catch (_) {
      // No settings yet: the usual size.
    }
  }

  /// Takes up the saved size again, after an import changed it.
  Future<void> reload() async {
    _picked = false;
    await _load();
  }

  /// Goes to [step], kept within the row, and answers with the step it is
  /// at from now on. Nothing is saved when that is the step it had.
  int set(int step) {
    final next = HelpZoom.clamp(step);
    if (next == state) return next;
    _picked = true;
    state = next;
    unawaited(
      ref
          .read(settingsStoreProvider)
          .saveString(SettingsStore.helpTextSize, HelpZoom.text(next))
          .catchError((Object e) => debugPrint('Could not save the help text size: $e')),
    );
    return next;
  }

  /// [by] steps bigger, or smaller for a negative [by], stopping at the ends.
  int step(int by) => set(state + by);
}
