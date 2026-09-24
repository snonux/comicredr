import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reader_input/reader_input.dart';

/// Where `keys.toml` is read from: `COMICREDR_KEYS` when set, else
/// `~/.config/comicredr/keys.toml` (or under `$XDG_CONFIG_HOME`) on Linux
/// and `Android/data/org.snonux.comicredr/files/keys.toml` on the phone,
/// which `adb push` and a file manager can both reach.
Future<String?> keysFilePath() async {
  final named = Platform.environment['COMICREDR_KEYS'];
  if (named != null && named.isNotEmpty) return named;
  if (Platform.isAndroid) {
    try {
      final d = await getExternalStorageDirectory();
      return d == null ? null : '${d.path}/keys.toml';
    } catch (_) {
      return null;
    }
  }
  final xdg = Platform.environment['XDG_CONFIG_HOME'];
  final home = Platform.environment['HOME'];
  final config = xdg != null && xdg.isNotEmpty ? xdg : (home == null ? null : '$home/.config');
  return config == null ? null : '$config/comicredr/keys.toml';
}

/// The live keymap: the defaults with the user's `keys.toml` over them,
/// when there is one. Read once at start.
Future<({KeymapLoad load, String? path})> loadKeymap() async {
  final path = await keysFilePath();
  if (path == null || !File(path).existsSync()) {
    return (load: KeymapLoad(Keymap.defaults(), const []), path: null);
  }
  try {
    final load = keymapFromToml(await File(path).readAsString());
    for (final w in load.warnings) {
      debugPrint(w);
    }
    return (load: load, path: path);
  } catch (e) {
    return (load: KeymapLoad(Keymap.defaults(), ['Could not read $path: $e']), path: path);
  }
}
