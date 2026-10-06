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

/// `gc` in the library, on the selected cover or the marked comics, and
/// Collection in the marks bar: asks for a collection, then puts every one
/// of [books] that is here in it ([collectBooks]). Comics only on S3 are
/// left out; with nothing else there is no question.
Future<bool> addBooksToCollection(BuildContext context, WidgetRef ref, List<LibraryBook> books) {
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) return Future.value(false);
  return collectBooks(context, ref, todo);
}

/// Asks for a collection for [books] and puts them in it: what
/// [addBooksToCollection] does, and the details' "Add to a collection" for
/// its one book. False when the question was left or the index refused.
///
/// A comic that is in the collection already is left alone
/// ([LibraryStore.addToCollection]): its row and its sidecar are not
/// written, and the notice counts only the ones really added, as the
/// reader's `gc` says "Already in X".
///
/// When the index refuses part of the way, the comics after that one are
/// not tried, the ones added before it stay added and have their sidecars
/// written, and the notice counts all three kinds: added, already in the
/// collection, and not added (the refused one and those never tried), see
/// [notAddedNotice]. The error itself goes to the log, not to the reader.
Future<bool> collectBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  // Nothing is awaited before this: the dialog goes up in the key press's
  // own call, so a name typed straight after gc is the dialog's.
  final name = await askCollection(context, ref, what: collectionWhat(books), keys: books.map((b) => b.key));
  if (name == null) return false;
  final added = <LibraryBook>[];
  // The comics the index answered for, added or in the collection already.
  var done = 0;
  try {
    for (final b in books) {
      if (await store.addToCollection(b.key, name)) added.add(b);
      done++;
    }
  } catch (e) {
    debugPrint('Could not add ${books[done].path} to the collection $name: $e');
  }
  // Also after a failure part of the way: the ones added are in the index.
  await _writeSidecars(sidecars, added);
  final already = done - added.length, notAdded = books.length - done;
  final said = notAdded == 0
      ? collectedNotice(added.length, books.length, name)
      : notAddedNotice(
          added: added.length,
          already: already,
          notAdded: notAdded,
          name: name,
          only: books.length == 1 ? books.single.name : null,
        );
  // In place of a notice still up (the one of the gc before this one), not
  // queued behind it.
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(said)));
  return notAdded == 0;
}

/// `1 was`, `3 were`: the comics a collection held already.
String _wasOrWere(int n) => n == 1 ? '1 was' : '$n were';

/// What [collectBooks] says after putting [added] of the [asked] comics in
/// the collection [name], the rest being in it already.
String collectedNotice(int added, int asked, String name) {
  final already = asked - added;
  if (already == 0) return '${comicsCount(added)} added to $name';
  if (added == 0) return asked == 1 ? 'Already in $name' : 'All $asked comics are already in $name';
  return '${comicsCount(added)} added to $name; ${_wasOrWere(already)} already in it';
}

/// What [collectBooks] says when the index failed while putting comics in
/// the collection [name]: how many were [added] before that, how many were
/// in it [already], and how many were [notAdded] (the one refused and the
/// ones after it, never tried; at least one). Each count is left out when
/// it is zero, so the three always add up to the comics asked for. [only]
/// is the comic's name when just one was asked for (the details' button),
/// which is then named instead of counted. The reason is a plain line: the
/// error is in the log.
String notAddedNotice({
  required int added,
  required int already,
  required int notAdded,
  required String name,
  String? only,
}) {
  const why = 'the library could not be updated';
  if (only != null) return 'Could not add $only to $name: $why';
  if (added == 0 && already == 0) return 'Could not add the $notAdded comics to $name: $why';
  final before = [
    if (added > 0) '${comicsCount(added)} added to $name',
    if (already > 0) '${_wasOrWere(already)} already in ${added > 0 ? 'it' : name}',
  ];
  return '${before.join('; ')}; $notAdded not added: $why';
}
