import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'data/app_database.dart';
import 'platform/file_system.dart';

/// The app index. Overridden with an in-memory database in tests.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final fileSystemProvider = Provider<PlatformFileSystem>((ref) => const IoFileSystem());

/// The keymap as loaded at start: the defaults, with the user's
/// `keys.toml` over them when there is one (main.dart overrides this), and
/// what was wrong in that file.
final keymapLoadProvider = Provider<({KeymapLoad load, String? path})>(
  (ref) => (load: KeymapLoad(Keymap.defaults(), const []), path: null),
);

/// The live keymap.
final keymapProvider = Provider<Keymap>((ref) => ref.watch(keymapLoadProvider).load.keymap);
