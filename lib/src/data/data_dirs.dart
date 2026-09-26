import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app's id, which names its folders under `~/.local/share` and
/// `~/.cache` on Linux.
const appId = 'org.snonux.comicredr';

/// The name of the app's own folder inside `~/Comics`.
const comicsDataName = '.comicredr';

/// Where this install keeps what is not in a sidecar: the index database
/// and installed models ([data]), covers and page thumbnails ([cache]), and
/// `keys.toml` ([keys]).
typedef AppDirs = ({String data, String cache, String? keys, bool inComics});

Future<AppDirs>? _dirs;
Map<String, String>? _environment;

/// This install's folders, worked out once per run (see [comicsDataFolder]).
/// `main` makes them before the database opens.
Future<AppDirs> appDirs() => _dirs ??= _resolve();

/// The environment `HOME` and the XDG folders are read from: the process's
/// own, unless a test swapped in a scratch home ([debugUseHome]).
Map<String, String> get appEnvironment => _environment ?? Platform.environment;

/// Makes [home] the app's home for the rest of the run: `~/Comics`, the app
/// data folder, `keys.toml` and installed models are all looked for under
/// it, and the app data goes in its XDG folders. `test/flutter_test_config.dart`
/// calls it before every test file, because widget tests run the real
/// start-up: with the real HOME they scanned the developer's `~/Comics`
/// into a new `~/Comics/.comicredr` and wrote test positions into its
/// sidecars.
@visibleForTesting
void debugUseHome(String home) {
  _environment = {...Platform.environment, 'HOME': home}
    ..remove('XDG_DATA_HOME')
    ..remove('XDG_CONFIG_HOME')
    ..remove('XDG_CACHE_HOME');
  _dirs = Future.value((
    data: xdgDataFolder()!,
    cache: p.join(home, '.cache', appId),
    keys: xdgKeysFile(),
    inComics: false,
  ));
}

/// The folder the index database and installed models live in.
Future<Directory> appDataDirectory() async => Directory((await appDirs()).data);

Future<AppDirs> _resolve() async {
  final comics = comicsDataFolder();
  if (comics != null) {
    return (data: comics, cache: p.join(comics, 'cache'), keys: p.join(comics, 'keys.toml'), inComics: true);
  }
  return (
    data: (await getApplicationSupportDirectory()).path,
    cache: (await getApplicationCacheDirectory()).path,
    keys: xdgKeysFile(),
    inComics: false,
  );
}

/// `~/Comics/.comicredr` when a new install should keep everything there:
/// on Linux, when `~/Comics` exists and there is no index database in the
/// usual place yet (`~/.local/share/org.snonux.comicredr/comicredr.sqlite`,
/// or under `$XDG_DATA_HOME`). An install that already has one keeps it
/// where it is, and without `~/Comics` the usual places are used. Decided
/// again at every start from what is on disk; nothing is moved. Null means
/// the usual places. Android always keeps its app-private folders: a
/// database on shared storage is slow and open to every app with access.
@visibleForTesting
String? comicsDataFolder({Map<String, String>? environment, bool? android}) {
  if (android ?? Platform.isAndroid) return null;
  final env = environment ?? appEnvironment;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  final xdg = env['XDG_DATA_HOME'];
  final dataHome = xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.local', 'share');
  // path_provider falls back to a folder named after the executable.
  for (final name in [appId, 'comicredr']) {
    if (File(p.join(dataHome, name, 'comicredr.sqlite')).existsSync()) return null;
  }
  final comics = p.join(home, 'Comics');
  return Directory(comics).existsSync() ? p.join(comics, comicsDataName) : null;
}

/// `~/.config/comicredr/keys.toml`, or under `$XDG_CONFIG_HOME`.
String? xdgKeysFile([Map<String, String>? environment]) {
  final env = environment ?? appEnvironment;
  final xdg = env['XDG_CONFIG_HOME'];
  final home = env['HOME'];
  final config = xdg != null && xdg.isNotEmpty ? xdg : (home == null ? null : p.join(home, '.config'));
  return config == null ? null : p.join(config, 'comicredr', 'keys.toml');
}

/// The usual Linux data folder, where `make install-model` put models
/// before the app could live in `~/Comics`.
String? xdgDataFolder([Map<String, String>? environment]) {
  final env = environment ?? appEnvironment;
  final xdg = env['XDG_DATA_HOME'];
  final home = env['HOME'];
  final data = xdg != null && xdg.isNotEmpty ? xdg : (home == null ? null : p.join(home, '.local', 'share'));
  return data == null ? null : p.join(data, appId);
}
