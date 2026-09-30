import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sidecar_sync.dart';
import '../reader/reader_notifier.dart';
import '../reader/reset_dialog.dart';
import 'book_detail.dart';
import 'collection_dialog.dart';
import 'delete_book.dart';
import 'library_store.dart';
import 'providers.dart';

/// The library's actions on several marked comics at once (Shift+arrows,
/// `V`, Ctrl+A, Ctrl/Shift+click, Select on a phone): each asks once for
/// the lot, where the action on one comic asks, and says in one notice
/// what it did. Each returns whether it went ahead, so the marks are
/// cleared only then. S3 uploads and removals are in s3_actions.dart.

/// `1 comic`, `5 comics`.
String comicsCount(int n) => n == 1 ? '1 comic' : '$n comics';

/// Writes the sidecar of each of [books] after a change in the index, so it
/// travels. A sidecar that can't be written catches up with the next change.
Future<void> _writeSidecars(SidecarSync sidecars, Iterable<LibraryBook> books) async {
  for (final b in books) {
    try {
      await sidecars.writeBeside(b.path, b.key, folder: b.isFolder);
    } catch (e) {
      debugPrint('Could not write the sidecar of ${b.path}: $e');
    }
  }
}

/// Deletes the marked [books] after one question for all of them: `gd` or
/// Shift+Delete with comics marked, or Delete in the marks bar. Comics only
/// on S3 are taken off S3 when "Delete here and from S3" is picked, and
/// left alone otherwise. [beforeDelete] runs once it is confirmed.
Future<bool> deleteLibraryBooks(
  BuildContext context,
  WidgetRef ref,
  List<LibraryBook> books, {
  void Function()? beforeDelete,
}) async {
  if (books.length == 1 && !books.single.remoteOnly) {
    return deleteLibraryBook(context, ref, books.single, beforeDelete: beforeDelete);
  }
  final messenger = ScaffoldMessenger.of(context);
  // Read up front: the widget [ref] belongs to may be gone after the dialog.
  final sidecars = ref.read(sidecarSyncProvider), store = ref.read(libraryStoreProvider);
  final coverDir = ref.read(coverDirProvider), container = ProviderScope.containerOf(context);
  final s3 = ref.read(s3SyncProvider);
  final local = books.where((b) => !b.remoteOnly).toList();
  final remote = books.where((b) => b.remoteOnly).toList();
  final facts = [
    for (final b in local)
      (await deleteFacts(b.name, b.path, folder: b.isFolder, pages: b.pageCount)).withS3(b.s3 != null),
  ];
  if (!context.mounted) return false;
  final choice = await askDeleteMany(context, facts, remoteOnly: remote.length);
  if (choice == DeleteChoice.cancel) return false;
  final open = container.read(readerProvider).book?.key;
  if (open != null && local.any((b) => b.key == open)) await container.read(readerProvider.notifier).close();
  beforeDelete?.call();
  var deleted = 0;
  final failed = <String>[];
  final stuck = <String>[];
  final offS3 = <String>[];
  for (final b in local) {
    try {
      stuck.addAll(
        await deleteComic(
          path: b.path,
          contentKey: b.key,
          folder: b.isFolder,
          sidecars: sidecars,
          store: store,
          coverDir: coverDir,
          keepCover: b.s3 != null && choice == DeleteChoice.here,
        ),
      );
      deleted++;
      if (b.s3 != null && choice == DeleteChoice.everywhere) offS3.add(b.key);
    } on FileSystemException catch (e) {
      failed.add('${b.name}: ${e.message}');
    } catch (e) {
      // The file went first, so this is the index or a sidecar afterwards.
      deleted++;
      failed.add('${b.name} was deleted, but the library could not be updated: $e');
    }
  }
  if (choice == DeleteChoice.everywhere) offS3.addAll(remote.map((b) => b.key));
  if (offS3.isNotEmpty) await s3.removeFromS3(offS3);
  final parts = [
    if (deleted > 0) '${comicsCount(deleted)} deleted',
    if (choice == DeleteChoice.everywhere && remote.isNotEmpty) '${comicsCount(remote.length)} taken off S3',
    if (failed.isNotEmpty)
      'could not delete ${failed.first}${failed.length > 1 ? ' and ${failed.length - 1} more' : ''}',
    if (stuck.isNotEmpty) '${stuck.length == 1 ? 'a sidecar' : '${stuck.length} sidecars'} could not be removed',
  ];
  messenger.showSnackBar(SnackBar(content: Text(parts.isEmpty ? 'Nothing deleted' : parts.join('; '))));
  return true;
}

/// Resets the marked [books] after one question: `X` with comics marked, or
/// Reset in the marks bar. Comics only on S3 have nothing here to reset.
Future<bool> resetBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) return false;
  if (todo.length == 1) {
    return resetBook(context, ref, todo.single);
  }
  final messenger = ScaffoldMessenger.of(context);
  final sidecars = ref.read(sidecarSyncProvider);
  final scope = await askReset(context, comicsCount(todo.length), count: todo.length);
  if (scope == null) return false;
  var stuck = 0;
  final failed = <String>[];
  for (final b in todo) {
    try {
      if (!await sidecars.reset(b.key, everything: scope == ResetScope.everything)) stuck++;
    } catch (e) {
      failed.add('${b.name}: $e');
    }
  }
  final done = todo.length - failed.length;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        [
          scope == ResetScope.everything
              ? '${comicsCount(done)} start from scratch'
              : "${comicsCount(done)}' panels will be found again",
          if (stuck > 0) "the files beside ${comicsCount(stuck)} can't be changed, so it may come back",
          if (failed.isNotEmpty) 'could not reset ${failed.first}',
        ].join('; '),
      ),
    ),
  );
  return true;
}

/// `*` with comics marked, or Favourite in the marks bar: all of [books]
/// into the Favourites, or, when every one is a favourite already, all out,
/// with Undo.
Future<bool> toggleFavourites(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  final on = !todo.every((b) => b.favourite);
  final changed = todo.where((b) => b.favourite != on).toList();
  try {
    for (final b in changed) {
      await store.setFavourite(b.key, on);
    }
  } catch (e) {
    debugPrint('Could not change the favourites: $e');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Could not change the favourites')));
    return false;
  }
  await _writeSidecars(sidecars, changed);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          on
              ? '${comicsCount(changed.length)} added to Favourites'
              : '${comicsCount(changed.length)} taken out of Favourites',
        ),
        action: on
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  for (final b in changed) {
                    await store.setFavourite(b.key, true);
                  }
                  await _writeSidecars(sidecars, changed);
                },
              ),
      ),
    );
  return true;
}

/// Collection in the marks bar: asks for a collection, then puts every one
/// of [books] in it.
Future<bool> addBooksToCollection(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  final name = await askCollection(context, ref, todo);
  if (name == null) return false;
  try {
    for (final b in todo) {
      await store.addToCollection(b.key, name);
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not add them to $name: $e')));
    return false;
  }
  await _writeSidecars(sidecars, todo);
  messenger.showSnackBar(SnackBar(content: Text('${comicsCount(todo.length)} added to $name')));
  return true;
}
