import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import '../reader/guided.dart';
import '../reader/reader_notifier.dart';
import 'library_store.dart';
import 'providers.dart';
import 'scanner.dart';

enum LibraryTab {
  reading('Reading', Icons.auto_stories),
  series('Series', Icons.collections_bookmark),
  books('Books', Icons.menu_book),
  folders('Folders', Icons.folder);

  const LibraryTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// One cover in a grid: a book, or a series standing for its books.
sealed class _Item {
  String get id;
}

class _BookItem extends _Item {
  _BookItem(this.book);
  final LibraryBook book;
  @override
  String get id => 'b:${book.key}';
}

class _SeriesItem extends _Item {
  _SeriesItem(this.series);
  final LibrarySeries series;
  @override
  String get id => 's:${series.id}';
}

/// The library (design plan sections 4 and 8): what you are reading, your
/// series, every book, and the folders they come from, as cover grids with a
/// search field. Keys and touch drive it through the same intents as the
/// reader: `hjkl` and the arrows move between covers, Enter opens, `/`
/// searches, Tab changes tab, Esc backs out.
///
/// Layout follows the plan's breakpoints: bottom navigation under 600 dp, a
/// navigation rail from 600, and a detail pane beside the grid over 1000.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({
    super.key,
    required this.onAddRoot,
    required this.onOpenFile,
    required this.onOpenFolder,
    this.keysFocus,
    this.pending = '',
  });

  /// Where keys go outside the search field, to hand focus back on Enter.
  final FocusNode? keysFocus;

  final VoidCallback onAddRoot;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenFolder;

  /// The half-typed key sequence, for the status line.
  final String pending;

  @override
  ConsumerState<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends ConsumerState<LibraryScreen> {
  LibraryTab? _tab;
  int? _series; // The series drilled into on the Series tab.
  String? _seriesSelected; // The series to select again when backing out.
  String _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  String? _selected;
  bool _detail = false; // The narrow layout's full-screen detail page.

  // Grid geometry from the last layout, for keyboard movement.
  int _cols = 2;
  double _rowExtent = 300;
  double _viewport = 600;
  List<_Item> _items = const [];

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  LibraryTab get tab => _tab ?? LibraryTab.series;

  void _setTab(LibraryTab t) => setState(() {
    _tab = t;
    _series = null;
    _selected = null;
    _detail = false;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  /// Handles a library intent; false for one that means nothing here.
  bool handle(ReaderCommand c) {
    final n = _items.length;
    int? index() {
      final i = _items.indexWhere((it) => it.id == _selected);
      return i < 0 ? null : i;
    }

    void move(int by) {
      if (n == 0) return;
      final i = index();
      _select(i == null ? 0 : (i + by).clamp(0, n - 1).toInt());
    }

    switch (c.intent) {
      case ReaderIntent.nextStep:
        move(c.times);
      case ReaderIntent.prevStep:
        move(-c.times);
      case ReaderIntent.panDown:
        move(_cols * c.times);
      case ReaderIntent.panUp:
        move(-_cols * c.times);
      case ReaderIntent.nextPage:
        move(_cols * math.max<int>(1, _viewport ~/ _rowExtent) * c.times);
      case ReaderIntent.prevPage:
        move(-_cols * math.max<int>(1, _viewport ~/ _rowExtent) * c.times);
      case ReaderIntent.firstPage:
        if (n > 0) _select(0);
      case ReaderIntent.lastPage:
        if (n > 0) _select(c.count != null ? (c.count! - 1).clamp(0, n - 1).toInt() : n - 1);
      case ReaderIntent.activate:
        final i = index();
        if (i != null) _activate(_items[i]);
      case ReaderIntent.cycleModeForward:
        _setTab(LibraryTab.values[(tab.index + 1) % LibraryTab.values.length]);
      case ReaderIntent.cycleModeBack:
        _setTab(LibraryTab.values[(tab.index - 1) % LibraryTab.values.length]);
      case ReaderIntent.search:
        _searchFocus.requestFocus();
      case ReaderIntent.back:
        back();
      default:
        return false;
    }
    return true;
  }

  /// Esc: closes the detail page, then clears the search, then leaves the
  /// series. False when there is nothing left to back out of.
  bool back() {
    if (_detail) {
      setState(() => _detail = false);
    } else if (_query.isNotEmpty) {
      _search.clear();
      setState(() => _query = '');
    } else if (_series != null) {
      setState(() {
        _series = null;
        _selected = _seriesSelected;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    } else {
      return false;
    }
    return true;
  }

  void _select(int i) {
    setState(() => _selected = _items[i].id);
    _reveal();
  }

  /// Scrolls the selected cover into view.
  void _reveal() {
    final i = _items.indexWhere((it) => it.id == _selected);
    if (i < 0 || !_scroll.hasClients) return;
    final top = (i ~/ _cols) * _rowExtent;
    final pos = _scroll.position;
    double? to;
    if (top < pos.pixels) to = top;
    if (top + _rowExtent > pos.pixels + pos.viewportDimension) to = top + _rowExtent - pos.viewportDimension + 16;
    if (to != null) _scroll.jumpTo(to.clamp(0, pos.maxScrollExtent));
  }

  void _activate(_Item item) {
    switch (item) {
      case _SeriesItem(:final series):
        setState(() {
          _seriesSelected = item.id;
          _series = series.id;
          _selected = _BookItem(series.next).id;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      case _BookItem(:final book):
        read(book);
    }
  }

  void read(LibraryBook book, {Place? at}) => ref.read(readerProvider.notifier).open(book.path, at: at);

  /// A tap: selects, and a second tap on the selected cover opens it. On a
  /// phone-sized screen a tap on a book shows its detail page.
  void _tap(_Item item, {required bool wide}) {
    if (item is _BookItem && !wide) {
      setState(() {
        _selected = item.id;
        _detail = true;
      });
      return;
    }
    if (_selected == item.id || item is _SeriesItem) {
      _activate(item);
    } else {
      setState(() => _selected = item.id);
    }
  }

  List<_Item> _itemsFor(List<LibraryBook> books) {
    final q = _query.trim();
    switch (tab) {
      case LibraryTab.reading:
        final started = books.where((b) => b.started && b.matches(q)).toList()
          ..sort((a, b) {
            if (a.finished != b.finished) return a.finished ? 1 : -1;
            return (b.readAt ?? DateTime(0)).compareTo(a.readAt ?? DateTime(0));
          });
        return [for (final b in started) _BookItem(b)];
      case LibraryTab.series:
        final all = LibrarySeries.group(books);
        final open = all.where((s) => s.id == _series).firstOrNull;
        if (open != null) return [for (final b in open.books.where((b) => b.matches(q))) _BookItem(b)];
        return [
          for (final s in all.where((s) => s.matches(q)))
            s.books.length == 1 ? _BookItem(s.books.first) : _SeriesItem(s),
        ];
      case LibraryTab.books:
        return [
          for (final s in LibrarySeries.group(books))
            for (final b in s.books)
              if (b.matches(q)) _BookItem(b),
        ];
      case LibraryTab.folders:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(booksProvider).value ?? const <LibraryBook>[];
    final roots = ref.watch(rootsProvider).value;
    // Open on what you are reading when there is something; else the series.
    _tab ??= roots == null ? null : (books.any((b) => b.inProgress) ? LibraryTab.reading : LibraryTab.series);
    _items = _itemsFor(books);
    if (_selected != null && !_items.any((it) => it.id == _selected)) _selected = null;

    final empty = roots != null && roots.isEmpty && books.isEmpty;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        final rail = box.maxWidth >= 600;
        final selectedBook = switch (_items.where((it) => it.id == _selected).firstOrNull) {
          _BookItem(:final book) => book,
          _ => null,
        };
        final Widget body = empty
            ? _EmptyLibrary(
                onAddRoot: widget.onAddRoot,
                onOpenFile: widget.onOpenFile,
                onOpenFolder: widget.onOpenFolder,
              )
            : _detail && selectedBook != null && !wide
            ? BookDetail(book: selectedBook, onRead: read, onBack: back)
            : Column(
                children: [
                  _header(context, books),
                  Expanded(
                    child: tab == LibraryTab.folders ? _Folders(onAddRoot: widget.onAddRoot) : _grid(context, wide),
                  ),
                ],
              );
        final Widget? pane = !wide || empty || tab == LibraryTab.folders
            ? null
            : switch (_items.where((it) => it.id == _selected).firstOrNull) {
                _BookItem(:final book) => BookDetail(book: book, onRead: read),
                _SeriesItem(:final series) => _SeriesDetail(series: series, onRead: read),
                null => null,
              };
        final content = Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (rail && !empty)
                    NavigationRail(
                      selectedIndex: tab.index,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (i) => _setTab(LibraryTab.values[i]),
                      destinations: [
                        for (final t in LibraryTab.values)
                          NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                      ],
                    ),
                  Expanded(child: body),
                  if (pane != null) ...[const VerticalDivider(width: 1), SizedBox(width: 380, child: pane)],
                ],
              ),
            ),
            _LibraryStatus(books: books, pending: widget.pending, onFailures: () => _setTab(LibraryTab.folders)),
          ],
        );
        return Scaffold(
          body: SafeArea(child: content),
          bottomNavigationBar: rail || empty
              ? null
              : NavigationBar(
                  selectedIndex: tab.index,
                  onDestinationSelected: (i) => _setTab(LibraryTab.values[i]),
                  destinations: [
                    for (final t in LibraryTab.values) NavigationDestination(icon: Icon(t.icon), label: t.label),
                  ],
                ),
        );
      },
    );
  }

  Widget _header(BuildContext context, List<LibraryBook> books) {
    final theme = Theme.of(context);
    final series = _series == null ? null : LibrarySeries.group(books).where((s) => s.id == _series).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          if (series != null) ...[
            IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back to series', onPressed: back),
            Flexible(
              child: Text(series.name, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
          ] else ...[
            Text(tab.label, style: theme.textTheme.titleLarge),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: tab == LibraryTab.folders
                ? const SizedBox()
                : TextField(
                    key: const Key('search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search titles, series, creators (/)',
                      border: const OutlineInputBorder(),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(icon: const Icon(Icons.clear), onPressed: () => back()),
                    ),
                    onChanged: (q) => setState(() {
                      _query = q;
                      _selected = null;
                    }),
                    onSubmitted: (_) {
                      widget.keysFocus?.requestFocus();
                      if (_items.isNotEmpty) _select(0);
                    },
                  ),
          ),
          IconButton(
            key: const Key('addRoot'),
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Add a folder to the library (A)',
            onPressed: widget.onAddRoot,
          ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'Open a comic without adding it (o)',
            onPressed: widget.onOpenFile,
          ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, bool wide) {
    if (_items.isEmpty) {
      final text = _query.isNotEmpty
          ? 'Nothing matches "$_query".'
          : tab == LibraryTab.reading
          ? 'Books you start reading show up here.'
          : 'No books found yet.';
      return Center(child: Text(text, style: Theme.of(context).textTheme.bodyLarge));
    }
    return LayoutBuilder(
      builder: (context, box) {
        const pad = 12.0, gap = 12.0;
        _cols = math.max(2, (box.maxWidth - pad * 2 + gap) ~/ (160 + gap));
        final itemW = (box.maxWidth - pad * 2 - gap * (_cols - 1)) / _cols;
        final extent = itemW * 1.5 + 48;
        _rowExtent = extent + gap;
        _viewport = box.maxHeight;
        return GridView.builder(
          key: const Key('grid'),
          controller: _scroll,
          padding: const EdgeInsets.all(pad),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            mainAxisExtent: extent,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final item = _items[i];
            return _CoverCard(
              item: item,
              selected: item.id == _selected,
              onTap: () => _tap(item, wide: wide),
              onLongPress: () => setState(() {
                _selected = item.id;
                _detail = item is _BookItem;
              }),
            );
          },
        );
      },
    );
  }
}

/// A cover image from the cache, or a placeholder while the scan has not
/// made it yet.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.bookKey, this.width = 400});

  final String bookKey;
  final int width;

  @override
  Widget build(BuildContext context) {
    final dir = ProviderScope.containerOf(context).read(coverDirProvider);
    final file = File('$dir/$bookKey.jpg');
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.menu_book, size: 40)),
    );
    if (!file.existsSync()) return placeholder;
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: width,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

class _CoverCard extends StatelessWidget {
  const _CoverCard({required this.item, required this.selected, required this.onTap, required this.onLongPress});

  final _Item item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (book, title, subtitle, count) = switch (item) {
      _BookItem(:final book) => (book, book.name, book.subtitle, null),
      _SeriesItem(:final series) => (
        series.next,
        series.name,
        '${series.books.length} books${series.read > 0 ? ' · ${series.read} read' : ''}',
        series.books.length,
      ),
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
                    CoverImage(bookKey: book.key),
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
                    if (item is _BookItem && book.finished)
                      const Positioned(right: 6, top: 6, child: Icon(Icons.check_circle, color: Colors.greenAccent)),
                    if (item is _BookItem && book.inProgress)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(value: book.percent ?? 0, minHeight: 4),
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

/// A book's page: cover, what it is, where you are in it, its bookmarks.
class BookDetail extends ConsumerWidget {
  const BookDetail({super.key, required this.book, required this.onRead, this.onBack});

  final LibraryBook book;
  final void Function(LibraryBook, {Place? at}) onRead;
  final VoidCallback? onBack;

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
        FilledButton.icon(
          key: const Key('read'),
          onPressed: () => onRead(book),
          icon: const Icon(Icons.chrome_reader_mode),
          label: Text(book.inProgress ? 'Continue reading' : (book.finished ? 'Read again' : 'Read')),
        ),
        if (book.summary != null) ...[const SizedBox(height: 16), Text(book.summary!)],
        const SizedBox(height: 20),
        Text('Bookmarks', style: theme.textTheme.titleMedium),
        if (marks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'None yet. In the reader, mm bookmarks the page (the panel in guided view), ma sets mark a.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final m in marks)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: m.mark == null ? const Icon(Icons.bookmark) : CircleAvatar(radius: 12, child: Text(m.mark!)),
            title: Text('Page ${m.page + 1}${m.panel != null ? ', panel ${m.panel! + 1}' : ''}'),
            subtitle: Text(m.mark == null ? 'Bookmark' : "Mark '${m.mark}"),
            onTap: () => onRead(book, at: (page: m.page, panel: m.panel ?? 0)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: () => ref.read(libraryStoreProvider).deleteBookmark(m.id),
            ),
          ),
        const SizedBox(height: 16),
        SelectableText(book.path, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _SeriesDetail extends StatelessWidget {
  const _SeriesDetail({required this.series, required this.onRead});

  final LibrarySeries series;
  final void Function(LibraryBook, {Place? at}) onRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final next = series.next;
    return ListView(
      key: const Key('detail'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(series.name, style: theme.textTheme.headlineSmall),
        Text('${series.books.length} books · ${series.read} read'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => onRead(next),
          icon: const Icon(Icons.chrome_reader_mode),
          label: Text('${next.inProgress ? 'Continue' : 'Read'} ${next.name}'),
        ),
        const SizedBox(height: 12),
        Text('Enter or a tap shows the books', style: theme.textTheme.bodySmall),
        for (final b in series.books)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(b.name),
            subtitle: b.subtitle == null ? null : Text(b.subtitle!),
            trailing: b.finished
                ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                : b.inProgress
                ? Text('${((b.percent ?? 0) * 100).round()}%')
                : null,
            onTap: () => onRead(b),
          ),
      ],
    );
  }
}

class _Folders extends ConsumerWidget {
  const _Folders({required this.onAddRoot});

  final VoidCallback onAddRoot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roots = ref.watch(rootsProvider).value ?? const [];
    final status = ref.watch(scanStatusProvider).value ?? const ScanStatus();
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final r in roots)
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text(r.path),
            subtitle: Text('${r.books} books'),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove from the library (the files stay)',
              onPressed: () async {
                await ref.read(libraryStoreProvider).removeRoot(r.id);
              },
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: onAddRoot,
              icon: const Icon(Icons.create_new_folder),
              label: const Text('Add a folder (A)'),
            ),
            OutlinedButton.icon(
              onPressed: status.running ? null : () => ref.read(scannerProvider).scan(),
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan (R)'),
            ),
          ],
        ),
        if (status.failed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Could not read', style: theme.textTheme.titleMedium),
          for (final (path, why) in status.failed)
            ListTile(dense: true, title: Text(p.basename(path)), subtitle: Text(why)),
        ],
      ],
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onAddRoot, required this.onOpenFile, required this.onOpenFolder});

  final VoidCallback onAddRoot;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('ComicRedr', style: theme.textTheme.displaySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('addRootEmpty'),
              onPressed: onAddRoot,
              icon: const Icon(Icons.create_new_folder),
              label: const Text('Add your comics folder'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onOpenFile,
                  icon: const Icon(Icons.menu_book),
                  label: const Text('Open a comic'),
                ),
                OutlinedButton.icon(
                  onPressed: onOpenFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open a folder'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'A adds a folder of comics to the library. o opens a CBZ or PDF and O a folder of pages '
              'without adding them. Or drop either here. ? shows the keymap.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// The library's status line: a notice, the scan's progress, or a count.
class _LibraryStatus extends ConsumerWidget {
  const _LibraryStatus({required this.books, required this.pending, required this.onFailures});

  final List<LibraryBook> books;
  final String pending;
  final VoidCallback onFailures;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reader = ref.watch(readerProvider);
    final scan = ref.watch(scanStatusProvider).value ?? const ScanStatus();
    final series = books.map((b) => b.seriesId).toSet().length;
    final text =
        reader.message ??
        (scan.running
            ? scan.total == 0
                  ? 'Scanning the library folders…'
                  : 'Scanning: ${scan.done} / ${scan.total} new or changed books'
            : '${books.length} books in $series series'
                  '${scan.failed.isEmpty ? '' : '  ·  ${scan.failed.length} could not be read'}');
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reader.loading || (scan.running && scan.total > 0))
            LinearProgressIndicator(minHeight: 2, value: reader.loading ? null : scan.done / math.max(1, scan.total)),
          InkWell(
            onTap: scan.failed.isEmpty ? null : onFailures,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(text, key: const Key('status'), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    pending,
                    key: const Key('pending'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
