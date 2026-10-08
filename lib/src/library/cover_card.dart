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

/// The width covers of the usual size are decoded at, on every screen:
/// what they were decoded at before covers could be sized, so the memory
/// they take is the same for whoever never sizes them (0.96 MB a cover of
/// 400 x 600). It is more than a 160 px cover needs on a screen of one
/// pixel a point and less than the 490 device pixels of one on a 3x
/// phone, where the usual covers are a little softer than the 512 px
/// file could give.
const usualCoverDecodeWidth = 400;

/// The widths a cover of another size than the usual is decoded at. Only
/// these four, so that a pinch, a `+` or a window dragged wider does not
/// decode every cover on screen again at each new tile width while the
/// old sizes sit in the image cache. The small ones are for small covers:
/// there are many of those on a screen (about 200 of 72 px in a 1920 px
/// window), and at 400 px each they would take some 190 MB, more than the
/// 100 MB Flutter's image cache holds; at 128 px they take 20 MB. 512 is
/// what the cover files have.
const coverDecodeWidths = [128, 256, usualCoverDecodeWidth, 512];

/// The decode width for a cover drawn [px] device pixels wide in a grid
/// sized by hand: the first of [coverDecodeWidths] that covers it, else
/// the biggest. A tile wider than that shows the cover scaled up; the
/// file has no more.
int coverDecodeWidth(double px) => coverDecodeWidths.firstWhere((w) => w >= px, orElse: () => coverDecodeWidths.last);

/// What a tile [px] device pixels wide decodes: its cover [cover] pixels
/// wide, and in shuffle the page file [shuffled] pixels wide
/// ([ShufflePages.sizeFor]), decoded no wider than [cover].
///
/// At the usual cover size ([zoomed] false) these are what they were
/// before covers could be sized, on every screen: [usualCoverDecodeWidth]
/// and the 256 px page ([ShufflePages.width]). So memory, and which page
/// files get made, only change for a grid sized by hand; the price is
/// that on a dense phone, whose usual covers are some 490 device pixels
/// wide, they are not as sharp as their files allow.
({int cover, int shuffled}) coverPictureSizes(double px, {required bool zoomed}) => zoomed
    ? (cover: coverDecodeWidth(px), shuffled: ShufflePages.sizeFor(px))
    : (cover: usualCoverDecodeWidth, shuffled: ShufflePages.width);

/// A cover image from the cache, or a placeholder while the scan has not
/// made it yet.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.bookKey, this.width = usualCoverDecodeWidth});

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
    this.coverWidth = usualCoverDecodeWidth,
    this.shuffleSize = ShufflePages.width,
  });

  /// How many pixels wide the cover is decoded: [usualCoverDecodeWidth]
  /// at the usual size, else by the tile's width ([coverDecodeWidth]). A
  /// shuffled page is decoded no wider than this either.
  final int coverWidth;

  /// In shuffle, how many pixels wide the page's file is
  /// ([ShufflePages.sizeFor]).
  final int shuffleSize;

  /// Marked with the others for an action on several (`V`, Ctrl+click).
  final bool marked;

  final LibraryItem item;

  /// In shuffle, the page the tile shows instead of the cover.
  final int? shufflePage;

  /// The comic [shufflePage] is from, when it is not the tile's own: for a
  /// folder or a series, one of the comics in it.
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
    return InkWell(
      key: ValueKey(item.id),
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _picture(theme, book, count)),
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

  /// The comic the tile is, when it is one comic and not a series, a folder
  /// or a bookmark: only such a tile has the signs that are about a comic.
  LibraryBook? get _onlyBook => switch (item) {
    BookItem(:final book) => book,
    _ => null,
  };

  /// The tile's picture: the cover of [book] (or the shuffled page) with
  /// the selection's frame around it and the signs over it, [count] the
  /// comics of a series or folder.
  Widget _picture(ThemeData theme, LibraryBook? book, int? count) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 3),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(fit: StackFit.expand, children: [_cover(book), ..._cornerSigns(theme, count), ..._bookSigns(theme)]),
    ),
  );

  /// The cover of [book]: in shuffle one of its pages, and paler for a
  /// comic that is only on S3.
  Widget _cover(LibraryBook? book) {
    final cover = CoverImage(bookKey: book?.key, width: coverWidth);
    if ((shufflePage, shuffleBook ?? book) case (final page?, final from?) when !from.remoteOnly) {
      return ShuffledPage(book: from, page: page, size: shuffleSize, decodeWidth: coverWidth, cover: cover);
    }
    return (_onlyBook?.remoteOnly ?? false) ? Opacity(opacity: 0.45, child: cover) : cover;
  }

  /// The signs in the top corners that say what kind of tile it is: a
  /// folder's on the left, how many comics ([count]) on the right.
  List<Widget> _cornerSigns(ThemeData theme, int? count) => [
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
          decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
          child: Text('$count', style: theme.textTheme.labelMedium),
        ),
      ),
  ];

  /// The signs of one comic, in the order they are painted: favourite,
  /// completed, S3, the tint of a marked tile, and the line of how far it
  /// was read along the bottom.
  List<Widget> _bookSigns(ThemeData theme) {
    final book = _onlyBook;
    return [
      if (book != null && book.favourite)
        const Positioned(
          left: 6,
          top: 6,
          child: Icon(Icons.star, key: Key('favouriteBadge'), color: Colors.amber, shadows: [Shadow(blurRadius: 3)]),
        ),
      // Completed: marked so, or left on its last page.
      if (book != null && book.completed)
        const Positioned(
          right: 6,
          top: 6,
          child: Icon(Icons.check_circle, key: Key('completedBadge'), color: Colors.greenAccent),
        ),
      if (book?.s3 != null) Positioned(right: 6, bottom: 8, child: S3Badge(book: book!)),
      if (marked) _markedTint(theme),
      if (book != null && book.inProgress)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: LinearProgressIndicator(value: book.percent ?? 0, minHeight: 4),
        ),
    ];
  }

  /// What a marked tile has over its picture: a tint and a tick.
  Widget _markedTint(ThemeData theme) => Positioned.fill(
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
  );
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
