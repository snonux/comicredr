import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_paths.dart';
import '../reader/reader_notifier.dart';
import 'library_items.dart';
import 'library_panes.dart';
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
  });

  final LibraryItem item;

  /// In shuffle, the page the tile shows instead of the cover.
  final int? shufflePage;
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
                    if ((shufflePage, book) case (final page?, final book?))
                      ShuffledPage(
                        book: book,
                        page: page,
                        cover: CoverImage(bookKey: book.key),
                      )
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
