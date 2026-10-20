import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../hotkeys.dart';
import '../reader/reader_notifier.dart';
import '../undo_notice.dart';
import 'bulk_actions.dart' show comicsCount;
import 'providers.dart';

/// Clear the Reading list (`gR`, the library's menu; snonux, 2026-10-17):
/// after one question, every comic's reading status is forgotten, its
/// place on this device and its completed mark (`LibraryStore.clearReading`),
/// and its sidecar written, so the clearing travels to other devices. Says
/// so when there is nothing to clear and asks nothing. Returns whether it
/// went ahead.
Future<bool> clearReadingList(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  // Read up front: the widget [ref] belongs to may be gone after the dialog.
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  final reader = ref.read(readerProvider.notifier);
  final count = (await store.withReadingStatus()).length;
  if (!context.mounted) return false;
  if (count == 0) {
    showNotice(messenger, 'The Reading list is empty already');
    return false;
  }
  if (await askClearReading(context, count) != true) return false;
  // A comic open behind the library keeps saving its place: saved now, so
  // the clearing is not undone by a write that comes after it.
  await reader.flush();
  try {
    final keys = await store.clearReading();
    for (final key in keys) {
      final at = await sidecars.placeOf(key);
      if (at != null) await sidecars.writeBeside(at.path, key, folder: at.folder);
    }
    final n = keys.length;
    showNotice(messenger, 'Reading list cleared: ${comicsCount(n)} ${n == 1 ? 'starts' : 'start'} unread again');
  } catch (e) {
    showNotice(messenger, 'Could not clear the Reading list: $e', mustRead: true);
  }
  return true;
}

/// Asks before clearing the Reading list of [count] comics: Cancel has the
/// focus, so Enter clears nothing by accident.
Future<bool?> askClearReading(BuildContext context, int count) => showDialog<bool>(
  context: context,
  builder: (context) => DialogHotkeys(
    child: AlertDialog(
      title: const Text('Clear the Reading list?'),
      content: Text(
        count == 1
            ? 'Forgets where you are in 1 comic and whether it is completed, here and on the devices its sidecar '
                  'reaches. Bookmarks, reading history and collections stay.'
            : 'Forgets where you are in ${comicsCount(count)} and whether they are completed, here and on the devices '
                  'their sidecars reach. Bookmarks, reading history and collections stay.',
      ),
      actions: [
        TextButton(
          key: const Key('clearReading-cancel'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Mnemonic('Cancel'),
        ),
        FilledButton(
          key: const Key('clearReading-clear'),
          onPressed: () => Navigator.pop(context, true),
          child: const Mnemonic('Clear', letter: 'l'),
        ),
      ],
    ),
  ),
);
