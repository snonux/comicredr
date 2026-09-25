import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reader_input/reader_input.dart';

import '../data/data_dirs.dart';

/// Where `keys.toml` is read from: `COMICREDR_KEYS` when set;
/// `Android/data/org.snonux.comicredr/files/keys.toml` on the phone, which
/// `adb push` and a file manager can both reach; on Linux
/// `~/Comics/.comicredr/keys.toml` when the app keeps its data there
/// ([appDirs]), unless only `~/.config/comicredr/keys.toml` exists, which
/// is otherwise the place (or under `$XDG_CONFIG_HOME`).
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
  final dirs = await appDirs();
  final xdg = xdgKeysFile();
  if (dirs.inComics && !File(dirs.keys!).existsSync() && xdg != null && File(xdg).existsSync()) return xdg;
  return dirs.keys;
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
