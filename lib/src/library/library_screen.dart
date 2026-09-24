import 'dart:io';
import 'dart:math' as math;

import 'package:comic_formats/comic_formats.dart' show naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import '../reader/guided.dart';
import '../reader/reader_notifier.dart';
import '../version.dart';
import 'settings_dialog.dart';
import 'library_store.dart';
import 'providers.dart';
import 'scanner.dart';

enum LibraryTab {
  reading('Reading', Icons.auto_stories),
  series('Series', Icons.collections_bookmark),
  books('Books', Icons.menu_book),
  collections('Collections', Icons.label_outline),
  history('History', Icons.history),
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

class _FolderItem extends _Item {
  _FolderItem(this.folder);
  final LibraryFolder folder;
  @override
  String get id => 'f:${folder.path}';
}

/// The library (design plan sections 4 and 8): what you are reading, your
/// series, every book, and the folders they come from, as cover grids with a
/// search field. Keys and touch drive it through the same intents as the
/// reader: `hjkl` and the arrows move between covers, Enter opens, `/`
/// searches, Tab changes tab, Esc backs out. The Folders tab walks the
/// folders on disk: Enter goes into a folder, Esc back up.
///
/// Layout follows the plan's breakpoints: bottom navigation under 600 dp, a
/// navigation rail from 600, and a detail pane beside the grid over 1000.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({
    super.key,
    required this.onAddRoot,
    required this.onOpenFile,
    required this.onOpenFolder,
    this.onExportSidecars,
    this.keysFocus,
    this.pending = '',
  });

  /// Where keys go outside the search field, to hand focus back on Enter.
  final FocusNode? keysFocus;

  final VoidCallback onAddRoot;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenFolder;

  /// Writes every book's sidecar to a folder of the person's choosing.
  final VoidCallback? onExportSidecars;

  /// The half-typed key sequence, for the status line.
  final String pending;

  @override
  ConsumerState<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends ConsumerState<LibraryScreen> {
  LibraryTab? _tab;
  int? _series; // The series drilled into on the Series tab.
  String? _seriesSelected; // The series to select again when backing out.
  String? _folder; // The folder walked into on the Folders tab, null at the top.
  String? _folderRoot; // The library folder it is under.
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
    // The Folders tab keeps its place; choosing it again goes to the top.
    if (t == LibraryTab.folders && tab == LibraryTab.folders) _folder = _folderRoot = null;
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
  /// series or goes up a folder. False when there is nothing left to back
  /// out of.
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
    } else if (tab == LibraryTab.folders && _folder != null) {
      if (_folder == _folderRoot) {
        final from = _folder!;
        _openFolder(null);
        setState(() => _selected = 'f:$from');
        WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      } else {
        _upTo(p.dirname(_folder!));
      }
    } else {
      return false;
    }
    return true;
  }

  /// Walks to [dir] under the library folder [root]; null goes to the top.
  void _openFolder(String? dir, {String? root}) {
    setState(() {
      _folder = dir;
      _folderRoot = dir == null ? null : root;
      _selected = null;
      _detail = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
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
      case _FolderItem(:final folder):
        _openFolder(folder.path, root: folder.root?.path ?? _folderRoot);
        // Select the first thing inside, once the grid has it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selected == null && _items.isNotEmpty) setState(() => _selected = _items.first.id);
        });
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
    if (_selected == item.id || item is _SeriesItem || item is _FolderItem) {
      _activate(item);
    } else {
      setState(() => _selected = item.id);
    }
  }

  /// The groups a cover can open: series, or collections on their tab.
  List<LibrarySeries> _groups(List<LibraryBook> books) =>
      tab == LibraryTab.collections ? collectionGroups(books) : LibrarySeries.group(books);

  /// Tabs that are lists of their own rather than cover grids.
  bool get _listTab => tab == LibraryTab.history;

  List<_Item> _itemsFor(List<LibraryBook> books, List<RootInfo> roots) {
    final q = _query.trim();
    switch (tab) {
      case LibraryTab.reading:
        final started = books.where((b) => b.started && b.matches(q)).toList()
          ..sort((a, b) {
            if (a.finished != b.finished) return a.finished ? 1 : -1;
            return (b.readAt ?? DateTime(0)).compareTo(a.readAt ?? DateTime(0));
          });
        return [for (final b in started) _BookItem(b)];
      case LibraryTab.series || LibraryTab.collections:
        final all = _groups(books);
        final open = all.where((s) => s.id == _series).firstOrNull;
        if (open != null) return [for (final b in open.books.where((b) => b.matches(q))) _BookItem(b)];
        return [
          for (final s in all.where((s) => s.matches(q)))
            s.books.length == 1 && tab == LibraryTab.series ? _BookItem(s.books.first) : _SeriesItem(s),
        ];
      case LibraryTab.books:
        return [
          for (final s in LibrarySeries.group(books))
            for (final b in s.books)
              if (b.matches(q)) _BookItem(b),
        ];
      case LibraryTab.folders:
        if (_folder == null) {
          return [
            for (final f in LibraryFolder.roots(roots, books))
              if (f.matches(q)) _FolderItem(f),
          ];
        }
        final (:folders, books: here) = LibraryFolder.children(_folder!, books);
        return [
          for (final f in folders)
            if (f.matches(q)) _FolderItem(f),
          for (final b in here)
            if (b.matches(q)) _BookItem(b),
        ];
      case LibraryTab.history:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(booksProvider).value ?? const <LibraryBook>[];
    final roots = ref.watch(rootsProvider).value;
    // Open on what you are reading when there is something; else the series.
    _tab ??= roots == null ? null : (books.any((b) => b.inProgress) ? LibraryTab.reading : LibraryTab.series);
    // A library folder taken out of the library while we are in it.
    if (_folderRoot != null && roots != null && !roots.any((r) => r.path == _folderRoot)) {
      _folder = _folderRoot = null;
    }
    _items = _itemsFor(books, roots ?? const []);
    if (_selected != null && !_items.any((it) => it.id == _selected)) _selected = null;

    final empty = roots != null && roots.isEmpty && books.isEmpty;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        final rail = box.maxWidth >= 600;
        final selectedItem = _items.where((it) => it.id == _selected).firstOrNull;
        final Widget body = empty
            ? _EmptyLibrary(
                onAddRoot: widget.onAddRoot,
                onOpenFile: widget.onOpenFile,
                onOpenFolder: widget.onOpenFolder,
              )
            : _detail && !wide && selectedItem is _BookItem
            ? BookDetail(book: selectedItem.book, onRead: read, onBack: back)
            : _detail && !wide && selectedItem is _FolderItem
            ? _FolderDetail(
                folder: selectedItem.folder,
                onOpen: () => _activate(selectedItem),
                onRead: read,
                onBack: back,
              )
            : Column(
                children: [
                  _header(context, books),
                  Expanded(
                    child: switch (tab) {
                      LibraryTab.history => _History(books: books, query: _query.trim(), onRead: read),
                      _ => _grid(context, wide),
                    },
                  ),
                ],
              );
        final Widget? pane = !wide || empty || _listTab
            ? null
            : switch (selectedItem) {
                _BookItem(:final book) => BookDetail(book: book, onRead: read),
                _SeriesItem(:final series) => _SeriesDetail(series: series, onRead: read),
                _FolderItem(:final folder) => _FolderDetail(
                  folder: folder,
                  onOpen: () => _activate(selectedItem),
                  onRead: read,
                ),
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
            _LibraryStatus(books: books, pending: widget.pending, onFailures: () => _showFailures(context)),
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
    final series = _series == null ? null : _groups(books).where((s) => s.id == _series).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          if (series != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: tab == LibraryTab.collections ? 'Back to collections' : 'Back to series',
              onPressed: back,
            ),
            Flexible(
              child: Text(series.name, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
          ] else if (tab == LibraryTab.folders && _folder != null) ...[
            IconButton(
              key: const Key('folderUp'),
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Up a folder (Esc)',
              onPressed: back,
            ),
            Flexible(flex: 2, child: _breadcrumb(theme)),
            const SizedBox(width: 12),
          ] else ...[
            Text(tab.label, style: theme.textTheme.titleLarge),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: TextField(
              key: const Key('search'),
              controller: _search,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search titles, series, creators (/)',
                border: const OutlineInputBorder(),
                suffixIcon: _query.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => back()),
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
          if (tab == LibraryTab.folders)
            IconButton(
              key: const Key('rescan'),
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan the library folders (R)',
              onPressed: () => ref.read(scannerProvider).scan(),
            ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'Open a comic without adding it (o)',
            onPressed: widget.onOpenFile,
          ),
          IconButton(
            key: const Key('settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => showSettings(context, onExportSidecars: widget.onExportSidecars),
          ),
        ],
      ),
    );
  }

  /// Where you are on the Folders tab: the library folder, then each
  /// folder down to this one. A tap on one goes there.
  Widget _breadcrumb(ThemeData theme) {
    final root = _folderRoot!;
    final crumbs = [
      root,
      for (final part in p.split(p.relative(_folder!, from: root)))
        if (part != '.') part,
    ];
    final paths = <String>[];
    for (final (i, c) in crumbs.indexed) {
      paths.add(i == 0 ? c : p.join(paths.last, c));
    }
    return SingleChildScrollView(
      key: const Key('breadcrumb'),
      scrollDirection: Axis.horizontal,
      reverse: true, // The folder you are in stays in view.
      child: Row(
        children: [
          TextButton(onPressed: () => _openFolder(null), child: const Text('Folders')),
          for (final (i, path) in paths.indexed) ...[
            const Icon(Icons.chevron_right, size: 18),
            i == paths.length - 1
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(p.basename(path), style: theme.textTheme.titleLarge),
                  )
                : TextButton(onPressed: () => _upTo(path), child: Text(p.basename(path))),
          ],
        ],
      ),
    );
  }

  /// Goes up to [dir], one of the folders above this one, with the folder
  /// on the way back down selected.
  void _upTo(String dir) {
    final from = p.join(dir, p.split(p.relative(_folder!, from: dir)).first);
    _openFolder(dir, root: _folderRoot);
    setState(() => _selected = 'f:$from');
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// The files the last scan could not read, and why.
  void _showFailures(BuildContext context) {
    final failed = ref.read(scanStatusProvider).value?.failed ?? const [];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Could not read'),
        content: SizedBox(
          width: 520,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (path, why) in failed)
                ListTile(dense: true, title: Text(p.basename(path)), subtitle: Text('$why\n$path')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  Widget _grid(BuildContext context, bool wide) {
    if (_items.isEmpty) {
      final text = _query.isNotEmpty
          ? 'Nothing matches "$_query".'
          : tab == LibraryTab.folders
          ? (_folder == null ? 'No library folders yet. A adds one.' : 'No books in this folder any more.')
          : tab == LibraryTab.reading
          ? 'Books you start reading show up here.'
          : tab == LibraryTab.collections
          ? 'No collections yet. Open a book\'s details and add it to one.'
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
                _detail = item is _BookItem || item is _FolderItem;
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
      _FolderItem(:final folder) => (folder.books.first, folder.name, _folderCount(folder), folder.books.length),
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
                    if (item is _FolderItem)
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
                final name = await _askCollection(context, ref, book);
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
            title: Text('Page ${m.page + 1}${isPanel(m.panel) ? ', panel ${m.panel! + 1}' : ''}'),
            subtitle: Text(m.mark == null ? 'Bookmark' : "Mark '${m.mark}"),
            // Without a panel, guided view shows the page whole.
            onTap: () => onRead(book, at: (page: m.page, panel: m.panel ?? pageStart)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: () => _changed(ref, () => ref.read(libraryStoreProvider).deleteBookmark(m.id)),
            ),
          ),
        const SizedBox(height: 16),
        SelectableText(book.path, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

extension on BookDetail {
  /// Runs a change to the book in the index, then writes its sidecar.
  Future<void> _changed(WidgetRef ref, Future<void> Function() change) async {
    await change();
    await ref.read(sidecarSyncProvider).writeBeside(book.path, book.key, folder: book.format == 'folder');
  }
}

/// Asks for a collection to put [book] in: one of those there are, or a
/// new name.
Future<String?> _askCollection(BuildContext context, WidgetRef ref, LibraryBook book) {
  final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
  final names = {for (final b in all) ...b.collections}.difference(book.collections.toSet()).toList()
    ..sort(naturalCompare);
  return showDialog<String>(
    context: context,
    builder: (_) => _CollectionDialog(book: book, names: names),
  );
}

class _CollectionDialog extends StatefulWidget {
  const _CollectionDialog({required this.book, required this.names});

  final LibraryBook book;

  /// Collections the book is not in yet.
  final List<String> names;

  @override
  State<_CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<_CollectionDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done(String name) {
    if (name.trim().isNotEmpty) Navigator.pop(context, name.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add ${widget.book.name} to a collection'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('collectionName'),
            controller: _field,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'New collection'),
            onSubmitted: _done,
          ),
          if (widget.names.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [for (final n in widget.names) ActionChip(label: Text(n), onPressed: () => _done(n))],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => _done(_field.text), child: const Text('Add')),
    ],
  );
}

/// Reading history: sittings with books, newest first, by day.
class _History extends ConsumerWidget {
  const _History({required this.books, required this.query, required this.onRead});

  final List<LibraryBook> books;
  final String query;
  final void Function(LibraryBook, {Place? at}) onRead;

  static String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _length(Duration d) => d.inMinutes < 1
      ? 'under a minute'
      : (d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(historyProvider).value ?? const <HistoryEntry>[];
    final byKey = {for (final b in books) b.key: b};
    final shown = [
      for (final e in entries)
        if (byKey[e.key] case final b? when b.matches(query)) (e, b),
    ];
    if (shown.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'What you read shows up here, sitting by sitting.' : 'Nothing matches "$query".',
          style: theme.textTheme.bodyLarge,
        ),
      );
    }
    final rows = <Widget>[];
    String? lastDay;
    for (final (e, b) in shown) {
      final day = _day(e.startedAt);
      if (day != lastDay) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(day, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        );
        lastDay = day;
      }
      rows.add(
        ListTile(
          key: Key('history-${e.key}-${e.startedAt.millisecondsSinceEpoch}'),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(width: 32, height: 48, child: CoverImage(bookKey: b.key, width: 96)),
          ),
          title: Text(b.name),
          subtitle: Text(
            '${_two(e.startedAt.hour)}:${_two(e.startedAt.minute)} · ${_length(e.duration)} · '
            '${e.pages} page${e.pages == 1 ? '' : 's'}',
          ),
          trailing: b.finished
              ? const Icon(Icons.check_circle, color: Colors.greenAccent)
              : b.inProgress
              ? Text('${((b.percent ?? 0) * 100).round()}%')
              : null,
          onTap: () => onRead(b),
        ),
      );
    }
    return ListView(key: const Key('history'), children: rows);
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

/// `12 books · 3 read` for a folder's cover.
String _folderCount(LibraryFolder folder) {
  final read = folder.books.where((b) => b.finished).length;
  return '${folder.books.length} ${folder.books.length == 1 ? 'book' : 'books'}${read > 0 ? ' · $read read' : ''}';
}

/// A folder's page: what is in it, a way in, and for a library folder a way
/// to take it out of the library.
class _FolderDetail extends ConsumerWidget {
  const _FolderDetail({required this.folder, required this.onOpen, required this.onRead, this.onBack});

  final LibraryFolder folder;
  final VoidCallback onOpen;
  final void Function(LibraryBook, {Place? at}) onRead;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final next = folder.books.where((b) => b.inProgress).firstOrNull;
    final root = folder.root;
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
            child: SizedBox(width: 200, height: 300, child: CoverImage(bookKey: folder.books.first.key, width: 512)),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Icon(Icons.folder),
            const SizedBox(width: 8),
            Expanded(child: Text(folder.name, style: theme.textTheme.headlineSmall)),
          ],
        ),
        const SizedBox(height: 8),
        Text(_folderCount(folder), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('openFolder'),
              onPressed: onOpen,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open the folder'),
            ),
            if (next != null)
              OutlinedButton.icon(
                onPressed: () => onRead(next),
                icon: const Icon(Icons.chrome_reader_mode),
                label: Text('Continue ${next.name}'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Enter or a tap opens the folder', style: theme.textTheme.bodySmall),
        if (root != null) ...[
          const SizedBox(height: 20),
          Text('A library folder', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('removeRoot'),
              onPressed: () => ref.read(libraryStoreProvider).removeRoot(root.id),
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Take out of the library (the files stay)'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SelectableText(folder.path, style: theme.textTheme.bodySmall),
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
    // Scrolls when large text or a phone in landscape leaves too little room.
    return Center(
      child: SingleChildScrollView(
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
                  const SizedBox(width: 12),
                  Text('ComicRedr $appVersion', key: const Key('version'), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
