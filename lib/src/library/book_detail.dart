import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../providers.dart';
import '../reader/bookmark_list.dart';
import '../reader/comic_details.dart';
import '../reader/guided.dart';
import '../reader/open_book.dart';
import '../reader/reader_notifier.dart';
import '../reader/reset_dialog.dart';
import 'collection_dialog.dart';
import 'cover_card.dart';
import 'delete_book.dart';
import 'edit_dialog.dart';
import 'library_store.dart';
import 'providers.dart';

/// A book's page: cover, what it is, where you are in it, its bookmarks.
class BookDetail extends ConsumerWidget {
  const BookDetail({super.key, required this.book, required this.onRead, this.onBack, this.onBeforeDelete});

  final LibraryBook book;
  final void Function(LibraryBook, {Place? at}) onRead;
  final VoidCallback? onBack;

  /// Called just before the book is deleted from its page, for the library
  /// to move its selection off it.
  final VoidCallback? onBeforeDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final marks = ref.watch(bookmarksProvider(book.key)).value ?? const [];
    final where = book.finished
        ? 'Finished'
        : book.started
        ? 'On page ${book.page! + 1} of ${book.pageCount}'
        : 'Not started · ${book.pageCount} pages';
    return ListView(
      key: const Key('detail'),
      padding: const EdgeInsets.all(16),
      children: [
        if (onBack != null)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back (Esc)', onPressed: onBack),
          ),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: 200, height: 300, child: CoverImage(bookKey: book.key, width: 512)),
          ),
        ),
        const SizedBox(height: 16),
        Text(book.name, style: theme.textTheme.headlineSmall),
        if (book.issueTitle != null) Text(book.issueTitle!, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          [
            if (book.year != null) '${book.year}',
            if (book.volume != null) 'Vol. ${book.volume}',
            book.format.toUpperCase(),
          ].join(' · '),
          style: theme.textTheme.bodyMedium,
        ),
        if (book.writers.isNotEmpty) Text('Written by ${book.writers.join(', ')}'),
        if (book.artists.isNotEmpty) Text('Art by ${book.artists.join(', ')}'),
        const SizedBox(height: 12),
        Text(where, key: const Key('where')),
        if (book.inProgress) ...[const SizedBox(height: 6), LinearProgressIndicator(value: book.percent ?? 0)],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('read'),
              onPressed: () => onRead(book),
              icon: const Icon(Icons.chrome_reader_mode),
              label: Text(book.inProgress ? 'Continue reading' : (book.finished ? 'Read again' : 'Read')),
            ),
            IconButton.outlined(
              key: const Key('favourite'),
              onPressed: () => setFavourite(ref, book, !book.favourite),
              icon: Icon(book.favourite ? Icons.star : Icons.star_outline, color: book.favourite ? Colors.amber : null),
              tooltip: book.favourite ? 'Take out of Favourites (*)' : 'Add to Favourites (*)',
            ),
            OutlinedButton.icon(
              key: const Key('editBook'),
              onPressed: () => editBook(context, ref, book),
              icon: const Icon(Icons.edit),
              label: const Text('Edit (e)'),
            ),
          ],
        ),
        if (book.summary != null) ...[const SizedBox(height: 16), Text(book.summary!)],
        const SizedBox(height: 20),
        Text('Collections', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final c in book.collections)
              InputChip(
                label: Text(c),
                onDeleted: () => _changed(ref, () => ref.read(libraryStoreProvider).removeFromCollection(book.key, c)),
                deleteButtonTooltipMessage: 'Take out of $c',
              ),
            ActionChip(
              key: const Key('addToCollection'),
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Add to a collection'),
              onPressed: () async {
                final name = await askCollection(context, ref, book);
                if (name != null) {
                  await _changed(ref, () => ref.read(libraryStoreProvider).addToCollection(book.key, name));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Bookmarks', style: theme.textTheme.titleMedium),
        if (marks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'None yet. In the reader, mm or the bookmark button marks the page (the panel in guided view); ma sets mark a.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final m in marks)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: m.mark == null ? const Icon(Icons.bookmark) : CircleAvatar(radius: 12, child: Text(m.mark!)),
            title: Text('P${describePlace(m).substring(1)}'),
            subtitle: Text(
              [m.mark == null ? 'Bookmark' : "Mark '${m.mark}", if (m.note != null) m.note!].join('  ·  '),
            ),
            // Without a panel, guided view shows the page whole.
            onTap: () => onRead(book, at: (page: m.page, panel: m.panel ?? pageStart)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_note),
                  tooltip: 'Note',
                  onPressed: () async {
                    final note = await askBookmarkNote(context, m);
                    if (note != null) await _changed(ref, () => ref.read(libraryStoreProvider).setNote(m.id, note));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () => _changed(ref, () => ref.read(libraryStoreProvider).deleteBookmark(m.id)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        SelectableText(book.path, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('bookDetails'),
              onPressed: () => showBookDetails(context, ref, book),
              icon: const Icon(Icons.info_outline),
              label: const Text('Details (I)'),
            ),
            OutlinedButton.icon(
              key: const Key('resetBook'),
              onPressed: () => resetBook(context, ref, book),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset this comic… (X)'),
            ),
            OutlinedButton.icon(
              key: const Key('deleteBook'),
              onPressed: () => deleteLibraryBook(context, ref, book, beforeDelete: () => onBeforeDelete?.call()),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete this comic… (gd)'),
            ),
          ],
        ),
      ],
    );
  }
}

extension on BookDetail {
  /// Runs a change to the book in the index, then writes its sidecar.
  Future<void> _changed(WidgetRef ref, Future<void> Function() change) async {
    await change();
    await ref.read(sidecarSyncProvider).writeBeside(book.path, book.key, folder: book.isFolder);
  }
}

/// Puts [book] in the Favourites collection or takes it out, then writes
/// its sidecar, so it travels. False when the index refused the change.
Future<bool> setFavourite(WidgetRef ref, LibraryBook book, bool on) async {
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  try {
    await store.setFavourite(book.key, on);
  } catch (e) {
    debugPrint('Could not change the favourites: $e');
    return false;
  }
  try {
    await sidecars.writeBeside(book.path, book.key, folder: book.isFolder);
  } catch (e) {
    // The index has it; the sidecar catches up with the next change.
    debugPrint('Could not write the sidecar of ${book.path}: $e');
  }
  return true;
}

/// The details view of [book] from the library: `I` on its cover, or the
/// button in its details. The book is opened for it and closed after.
/// Redo panels forgets its panels, which the reader finds again when the
/// book is opened.
Future<void> showBookDetails(BuildContext context, WidgetRef ref, LibraryBook book) async {
  final messenger = ScaffoldMessenger.of(context);
  // Read up front: the widget [ref] belongs to may be gone once the view closes.
  final store = ref.read(libraryStoreProvider), sidecars = ref.read(sidecarSyncProvider);
  final keymap = ref.read(keymapProvider);
  final OpenBook open;
  try {
    open = (await openBook(book.path)).withEdits(await store.edits(book.key));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open ${book.name}: $e')));
    return;
  }
  var redo = false;
  try {
    if (!context.mounted) return;
    await showComicDetails(
      context,
      open,
      closeKeys: {
        for (final b in keymap.bindings)
          if (b.intent == ReaderIntent.showDetails && b.keys.length == 1 && b.keys.single.length == 1) b.keys.single,
      },
      onRedoPanels: () async => redo = true,
    );
  } finally {
    await open.doc.close();
  }
  if (!redo) return;
  try {
    final ok = await sidecars.reset(book.key, everything: false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? "${book.name}'s panels will be found again"
              : "Reset ${book.name} here, but the file beside it can't be changed, so it may come back",
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not reset ${book.name}: $e')));
  }
}

/// Asks, then resets [book] from the library: `X` on its cover, or the
/// button in its details. Its panels are found again by the reader when it
/// is opened.
Future<void> resetBook(BuildContext context, WidgetRef ref, LibraryBook book) async {
  final messenger = ScaffoldMessenger.of(context);
  final sidecars = ref.read(sidecarSyncProvider);
  final scope = await askReset(context, book.name);
  if (scope == null) return;
  try {
    final ok = await sidecars.reset(book.key, everything: scope == ResetScope.everything);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? "Reset ${book.name} here, but the file beside it can't be changed, so it may come back"
              : scope == ResetScope.everything
              ? '${book.name} starts from scratch'
              : "${book.name}'s panels will be found again",
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not reset ${book.name}: $e')));
  }
}

/// Asks, then deletes [book] from the library: `gd` or Shift+Delete on
/// its cover, or the button in its details. [beforeDelete] runs once it
/// is confirmed, to move the selection off it.
Future<void> deleteLibraryBook(
  BuildContext context,
  WidgetRef ref,
  LibraryBook book, {
  void Function()? beforeDelete,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  // Read up front: the widget [ref] belongs to may be gone after the dialog.
  final sidecars = ref.read(sidecarSyncProvider), store = ref.read(libraryStoreProvider);
  final coverDir = ref.read(coverDirProvider), container = ProviderScope.containerOf(context);
  final folder = book.isFolder;
  final facts = await deleteFacts(book.name, book.path, folder: folder, pages: book.pageCount);
  if (!context.mounted || !await askDelete(context, facts)) return;
  // The reader may have it open behind a dialog opened from the library.
  if (container.read(readerProvider).book?.key == book.key) await container.read(readerProvider.notifier).close();
  beforeDelete?.call();
  try {
    final stuck = await deleteComic(
      path: book.path,
      contentKey: book.key,
      folder: folder,
      sidecars: sidecars,
      store: store,
      coverDir: coverDir,
    );
    messenger.showSnackBar(SnackBar(content: Text(deletedNotice(book.name, stuck))));
  } on FileSystemException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not delete ${book.name}: ${e.message}')));
  } catch (e) {
    // The file went first, so this is the index or a sidecar afterwards.
    messenger.showSnackBar(SnackBar(content: Text('Deleted ${book.name}, but the library could not be updated: $e')));
  }
}
