import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/settings_store.dart';
import '../providers.dart';
import '../reader/reader_notifier.dart';

/// The touch preset picked in Settings, kept in the settings table.
final touchPresetProvider = NotifierProvider<TouchPresetNotifier, TouchPreset>(TouchPresetNotifier.new);

class TouchPresetNotifier extends Notifier<TouchPreset> {
  bool _picked = false;
  bool _newPick = false;

  @override
  TouchPreset build() {
    unawaited(_load());
    return TouchPreset.standard;
  }

  Future<void> _load() async {
    try {
      final name = await ref.read(settingsStoreProvider).loadString(SettingsStore.touchPreset);
      if (!_picked) state = TouchPreset.byName(name);
    } catch (_) {
      // No settings yet: the standard preset.
    }
  }

  /// Whether a preset was picked since the last call, so the reader can
  /// show its zones once.
  bool takeNewPick() {
    final was = _newPick;
    _newPick = false;
    return was;
  }

  Future<void> pick(TouchPreset preset) async {
    _picked = true;
    _newPick = true;
    state = preset;
    await ref.read(settingsStoreProvider).saveString(SettingsStore.touchPreset, preset.name);
  }
}

/// What each gesture does: the preset, with `keys.toml`'s `[touch]` lines
/// over it.
final touchMapProvider = Provider<TouchMap>(
  (ref) => TouchMap.preset(ref.watch(touchPresetProvider)).withOverrides(ref.watch(keymapLoadProvider).load.touch),
);
