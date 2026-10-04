import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_paths.dart';
import '../data/s3_sync.dart';
import '../reader/reader_notifier.dart';
import 'library_items.dart';
import 'library_panes.dart';
import 'library_store.dart';
import 'providers.dart';
import 'shuffle.dart';

/// A cover image from the cache, or a placeholder while the scan has not
/// made it yet.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.bookKey, this.width = 400});

  /// Null for a library folder with no books in it yet: the placeholder.
  final String? bookKey;
  final int width;

  @override
  Widget build(BuildContext context) {
    final dir = ProviderScope.containerOf(context).read(coverDirProvider);
    final key = bookKey;
    final file = key == null ? null : File(coverFile(dir, key));
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.menu_book, size: 40)),
    );
    if (file == null || !file.existsSync()) return placeholder;
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: width,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.shufflePage,
    this.shuffleBook,
    this.marked = false,
  });

  /// Marked with the others for an action on several (`V`, Ctrl+click).
  final bool marked;

  final LibraryItem item;

  /// In shuffle, the page the tile shows instead of the cover.
  final int? shufflePage;

  /// The comic [shufflePage] is from, when it is not the tile's own: for a
  /// folder, one of the comics in it.
  final LibraryBook? shuffleBook;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (book, title, subtitle, count) = switch (item) {
      BookItem(:final book) => (book, book.name, book.subtitle, null),
      SeriesItem(:final series) => (
        series.next,
        series.name,
        '${series.books.length} books${series.read > 0 ? ' · ${series.read} read' : ''}',
        series.books.length,
      ),
      // A library folder can be empty (~/Comics before any comic is in it).
      FolderItem(:final folder) => (folder.books.firstOrNull, folder.name, folderCount(folder), folder.books.length),
      // Bookmarks are rows on their own tab, never covers.
      BookmarkItem(:final book, :final bookmark) => (book, book.name, describePlace(bookmark), null),
    };
    final onlyBook = switch (item) {
      BookItem(:final book) => book,
      _ => null,
    };
    return InkWell(
      key: ValueKey(item.id),
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 3),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if ((shufflePage, shuffleBook ?? book) case (final page?, final from?) when !from.remoteOnly)
                      ShuffledPage(
                        book: from,
                        page: page,
                        cover: CoverImage(bookKey: book?.key),
                      )
                    else if (onlyBook?.remoteOnly ?? false)
                      Opacity(opacity: 0.45, child: CoverImage(bookKey: book?.key))
                    else
                      CoverImage(bookKey: book?.key),
                    if (item is FolderItem)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(Icons.folder, size: 20, color: theme.colorScheme.onSecondaryContainer),
                        ),
                      ),
                    if (count != null)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('$count', style: theme.textTheme.labelMedium),
                        ),
                      ),
                    if (onlyBook != null && onlyBook.favourite)
                      const Positioned(
                        left: 6,
                        top: 6,
                        child: Icon(
                          Icons.star,
                          key: Key('favouriteBadge'),
                          color: Colors.amber,
                          shadows: [Shadow(blurRadius: 3)],
                        ),
                      ),
                    if (onlyBook != null && onlyBook.finished)
                      const Positioned(right: 6, top: 6, child: Icon(Icons.check_circle, color: Colors.greenAccent)),
                    if (onlyBook?.s3 != null) Positioned(right: 6, bottom: 8, child: S3Badge(book: onlyBook!)),
                    if (marked)
                      Positioned.fill(
                        child: ColoredBox(
                          color: theme.colorScheme.primary.withValues(alpha: 0.25),
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                Icons.check_circle,
                                key: const Key('markedTick'),
                                size: 28,
                                color: theme.colorScheme.primary,
                                shadows: const [Shadow(blurRadius: 3)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (onlyBook != null && onlyBook.inProgress)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(value: onlyBook.percent ?? 0, minHeight: 4),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          Text(
            subtitle ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The cloud in a cover's corner (design plan section 13): on S3 and in
/// step, something still to go up, the bucket out of reach, or on S3 only.
/// While the comic goes up or down, how far it got.
class S3Badge extends ConsumerWidget {
  const S3Badge({super.key, required this.book});

  final LibraryBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(s3StatusProvider).value ?? const S3Status();
    final shelf = book.s3;
    if (shelf == null) return const SizedBox.shrink();
    final out = status.reach == S3Reach.unreachable && shelf.mark != S3Mark.remote;
    final (icon, tip, name) = switch (shelf.mark) {
      _ when out => (Icons.cloud_off, 'On S3; the bucket is out of reach, saved here', 's3Unreachable'),
      S3Mark.synced => (Icons.cloud_done, 'On S3', 's3Synced'),
      S3Mark.waiting => (Icons.cloud_upload, 'On S3; changes waiting to go up', 's3Waiting'),
      S3Mark.remote => (Icons.cloud_download, 'On S3 only; not downloaded', 's3Remote'),
    };
    final theme = Theme.of(context);
    final done = status.transfers[book.key];
    return Tooltip(
      message: tip,
      child: Container(
        key: Key(name),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: out ? theme.colorScheme.errorContainer : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: out ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSecondaryContainer,
            ),
            if (done != null) ...[
              const SizedBox(width: 4),
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(value: done, strokeWidth: 2)),
            ],
          ],
        ),
      ),
    );
  }
}
