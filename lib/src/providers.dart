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

/// The live keymap. M9 loads a user `keys.toml` over these defaults.
final keymapProvider = Provider<Keymap>((ref) => Keymap.defaults());

/// The last command the reader dispatched. Until M3 there is no reader to
/// act on it, so the shell only shows it, which makes the keymap testable
/// by hand on both platforms.
final lastCommandProvider = NotifierProvider<LastCommand, ReaderCommand?>(LastCommand.new);

class LastCommand extends Notifier<ReaderCommand?> {
  @override
  ReaderCommand? build() => null;

  void set(ReaderCommand command) => state = command;
}
