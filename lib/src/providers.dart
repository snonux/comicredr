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

/// The keymap as loaded, and where from: the defaults, with the user's
/// `keys.toml` over them when there is one, and what was wrong in that
/// file.
typedef KeymapFile = ({KeymapLoad load, String? path});

/// The keymap as loaded at start (main.dart overrides this).
final startKeymapProvider = Provider<KeymapFile>((ref) => (load: KeymapLoad(Keymap.defaults(), const []), path: null));

/// The keymap as loaded again after Import settings wrote `keys.toml`;
/// null until then.
final reloadedKeymapProvider = NotifierProvider<ReloadedKeymap, KeymapFile?>(ReloadedKeymap.new);

class ReloadedKeymap extends Notifier<KeymapFile?> {
  @override
  KeymapFile? build() => null;

  void set(KeymapFile keymap) => state = keymap;
}

/// The keymap in use: the one loaded last.
final keymapLoadProvider = Provider<KeymapFile>(
  (ref) => ref.watch(reloadedKeymapProvider) ?? ref.watch(startKeymapProvider),
);

/// The live keymap.
final keymapProvider = Provider<Keymap>((ref) => ref.watch(keymapLoadProvider).load.keymap);

/// The folder the index database, covers and thumbnails are in (see
/// appDirs), shown in the `?` overlay. main.dart overrides this.
final appDataDirProvider = Provider<String?>((ref) => null);
