import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import '../data/settings_store.dart';
import '../reader/bookmark_list.dart';
import '../reader/guided.dart';
import '../reader/reader_notifier.dart';
import 'book_detail.dart';
import 'cover_card.dart';
import 'edit_dialog.dart';
import 'library_items.dart';
import 'library_panes.dart';
import 'library_status.dart';
import 'library_store.dart';
import 'providers.dart';
import 'settings_dialog.dart';
import 'shuffle.dart';

enum LibraryTab {
  reading('Reading', Icons.auto_stories),
  series('Series', Icons.collections_bookmark),
  books('Books', Icons.menu_book),
  collections('Collections', Icons.label_outline, short: 'Groups'),
  history('History', Icons.history),
  folders('Folders', Icons.folder),
  bookmarks('Bookmarks', Icons.bookmarks, short: 'Marks');

  const LibraryTab(this.label, this.icon, {String? short}) : short = short ?? label;

  final String label;

  /// The label under the phone's bottom tabs, where a long one wraps.
  final String short;
  final IconData icon;
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
    this.onExportSettings,
    this.onImportSettings,
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

  /// Everything but the comics to one file, and back from one.
  final VoidCallback? onExportSettings;
  final VoidCallback? onImportSettings;

  /// The half-typed key sequence, for the status line.
  final String pending;

  @override
  ConsumerState<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends ConsumerState<LibraryScreen> {
  LibraryTab? _tab;
  int? _series; // The series drilled into on the Series tab.
  bool _favourites = false; // The Favourites collection open on the Collections tab.
  String? _seriesSelected; // The series to select again when backing out.
  String? _folder; // The folder walked into on the Folders tab, null at the top.
  String? _folderRoot; // The library folder it is under.
  bool _rootListed = false; // _folderRoot has been seen among the roots.
  bool _autoFirst = false; // Keep the first item selected until a key or tap.
  String _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  String? _selected;
  Set<String> _selectedBooks = const {}; // The keys of the books it stands for.
  bool _detail = false; // The narrow layout's full-screen detail page.

  // Grid geometry from the last layout, for keyboard movement.
  int _cols = 2;
  double _rowExtent = 300;
  double _viewport = 600;
  List<LibraryItem> _items = const [];

  /// Shuffle on the Folders tab (`S`): random pages instead of covers,
  /// picked by [_seed].
  bool _shuffle = false;
  int _seed = 0;
  final _random = math.Random();

  @override
  void initState() {
    super.initState();
    unawaited(
      ref
          .read(settingsStoreProvider)
          .loadBool(SettingsStore.shuffle)
          .then((on) {
            if (on == true && mounted) setState(() => _shuffle = true);
          })
          .catchError((Object e) => debugPrint('Could not read the shuffle setting: $e')),
    );
    _reshuffle();
  }

  bool get shuffle => _shuffle;

  void _showSettings() => showSettings(
    context,
    onExportSidecars: widget.onExportSidecars,
    onExportSettings: widget.onExportSettings,
    onImportSettings: widget.onImportSettings,
  );

  /// Takes up the saved shuffle setting again, after an import changed it.
  Future<void> reloadSettings() async {
    try {
      final on = await ref.read(settingsStoreProvider).loadBool(SettingsStore.shuffle) ?? false;
      if (on == _shuffle || !mounted) return;
      if (on) _reshuffle();
      setState(() => _shuffle = on);
    } catch (e) {
      debugPrint('Could not read the shuffle setting: $e');
    }
  }

  /// Turns shuffle on or off, remembered for the next start. On picks new
  /// pages.
  void setShuffle(bool on) {
    if (on) _reshuffle();
    setState(() => _shuffle = on);
    unawaited(
      ref
          .read(settingsStoreProvider)
          .saveBool(SettingsStore.shuffle, on)
          .catchError((Object e) => debugPrint('Could not save the shuffle setting: $e')),
    );
  }

  /// New random pages for every tile.
  void _reshuffle() => _seed = _random.nextInt(1 << 32);

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
    _autoFirst = false;
    _series = null;
    _favourites = false;
    _selected = null;
    _detail = false;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  /// Handles a library intent; false for one that means nothing here.
  bool handle(ReaderCommand c) {
    _autoFirst = false;
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
        // Typing replaces the last search; arrows keep it. After the field
        // has taken focus, which places the cursor itself.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
        });
      case ReaderIntent.bookmarkList:
        _setTab(LibraryTab.bookmarks);
      case ReaderIntent.showFavourites:
        showFavourites();
      case ReaderIntent.toggleFavourite:
        if (_selectedItem case BookItem(:final book)) {
          unawaited(_toggleFavourite(book));
        }
      case ReaderIntent.remove when _favourites:
        if (_selectedItem case BookItem(:final book)) {
          unawaited(_toggleFavourite(book));
        }
      case ReaderIntent.remove:
        if (_selectedItem case BookmarkItem(:final bookmark, :final book)) {
          final i = index()!;
          unawaited(_bookmarkChanged(book, () => ref.read(libraryStoreProvider).deleteBookmark(bookmark.id)));
          // The next one down takes the selection, as in the reader's list.
          final next = i + 1 < n ? _items[i + 1] : (i > 0 ? _items[i - 1] : null);
          setState(() => _selected = next?.id);
        }
      case ReaderIntent.back:
        return back();
      case ReaderIntent.up:
        _folderUp();
      case ReaderIntent.toggleShuffle when tab == LibraryTab.folders:
        setShuffle(!_shuffle);
      case ReaderIntent.reshuffle when tab == LibraryTab.folders && _shuffle:
        setState(_reshuffle);
      case ReaderIntent.resetBook:
        if (_selectedItem case BookItem(:final book)) {
          unawaited(resetBook(context, ref, book).whenComplete(() => widget.keysFocus?.requestFocus()));
        }
      case ReaderIntent.deleteBook:
        if (_selectedItem case BookItem(:final book)) {
          unawaited(
            deleteLibraryBook(
              context,
              ref,
              book,
              beforeDelete: () => selectNeighbourOf(book.key),
            ).whenComplete(() => widget.keysFocus?.requestFocus()),
          );
        }
      case ReaderIntent.showDetails:
        if (_selectedItem case BookItem(:final book)) {
          unawaited(showBookDetails(context, ref, book).whenComplete(() => widget.keysFocus?.requestFocus()));
        }
      case ReaderIntent.editBook:
        final done = widget.keysFocus?.requestFocus;
        switch (_selectedItem) {
          case BookItem(:final book):
            unawaited(editBook(context, ref, book).whenComplete(() => done?.call()));
          case SeriesItem(:final series) when tab == LibraryTab.series:
            unawaited(renameSeries(context, ref, series).whenComplete(() => done?.call()));
          case BookmarkItem(:final bookmark, :final book):
            unawaited(_editNote(book, bookmark).whenComplete(() => done?.call()));
          default:
        }
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
    } else if (_series != null || _favourites) {
      setState(() {
        _series = null;
        _favourites = false;
        _selected = _seriesSelected;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    } else if (!_folderUp()) {
      return false;
    }
    return true;
  }

  /// Backspace, and Esc once nothing else is open: up to the folder above
  /// on the Folders tab. False at the top or on another tab.
  bool _folderUp() {
    if (tab != LibraryTab.folders || _folder == null) return false;
    _detail = false;
    if (_folder == _folderRoot) {
      final from = _folder!;
      _openFolder(null);
      setState(() => _selected = 'f:$from');
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    } else {
      _upTo(p.dirname(_folder!));
    }
    return true;
  }

  /// `gf`, or the star in the header: the Favourites collection, open on
  /// the Collections tab, with its first comic selected.
  void showFavourites() {
    _setTab(LibraryTab.collections);
    _search.clear();
    // Esc comes back out to the Favourites cover.
    final books = ref.read(booksProvider).value ?? const <LibraryBook>[];
    final group = collectionGroups(books).where((s) => s.name == favouritesCollection).firstOrNull;
    setState(() {
      _query = '';
      _favourites = true;
      _seriesSelected = group == null ? null : SeriesItem(group).id;
    });
    _autoFirst = true;
  }

  /// `*` on a cover or the star in the details: in the Favourites or out.
  /// Taken out in the Favourites view, the comic leaves it at once, the
  /// next one is selected, and a notice offers it back.
  Future<void> _toggleFavourite(LibraryBook book) async {
    final on = !book.favourite;
    if (!on && _favourites) {
      final i = _items.indexWhere((it) => it.id == _selected);
      if (i >= 0 && _items[i].id == BookItem(book).id) {
        final next = i + 1 < _items.length ? _items[i + 1] : (i > 0 ? _items[i - 1] : null);
        setState(() => _selected = next?.id);
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    final done = await setFavourite(ref, book, on);
    if (!done) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not change the favourites for ${book.name}')));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(on ? '${book.name} added to Favourites' : '${book.name} taken out of Favourites'),
          action: on ? null : SnackBarAction(label: 'Undo', onPressed: () => setFavourite(ref, book, true)),
        ),
      );
  }

  /// Shows [dir], under the library folder [root], on the Folders tab: for a
  /// folder opened from the command line, Open With or a drop.
  void showFolder(String dir, {required String root}) {
    _setTab(LibraryTab.folders);
    _openFolder(dir, root: root);
    _search.clear();
    setState(() => _query = '');
    _autoFirst = true;
  }

  /// Walks to [dir] under the library folder [root]; null goes to the top.
  void _openFolder(String? dir, {String? root}) {
    setState(() {
      if (root != _folderRoot) _rootListed = false;
      _autoFirst = false;
      _folder = dir;
      _folderRoot = dir == null ? null : root;
      // Each folder walked into gets pages of its own.
      _reshuffle();
      _selected = null;
      _detail = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _select(int i) {
    setState(() => _selected = _items[i].id);
    _reveal();
  }

  static Set<String> _books(LibraryItem? item) => switch (item) {
    BookItem(:final book) => {book.key},
    SeriesItem(:final series) => {for (final b in series.books) b.key},
    _ => const {},
  };

  /// The cover or row the selection is on, if it is still shown.
  LibraryItem? get _selectedItem => _items.where((it) => it.id == _selected).firstOrNull;

  /// The book [contentKey] is about to be deleted: the cover next to it
  /// takes the selection, the one after it or else the one before. A series
  /// that keeps other books stays selected.
  void selectNeighbourOf(String contentKey) {
    final i = _items.indexWhere((it) => _books(it).contains(contentKey));
    if (i < 0) return;
    final item = _items[i];
    if (item is SeriesItem && _books(item).length > 1) {
      setState(() => _selected = item.id);
      return;
    }
    final next = i + 1 < _items.length ? _items[i + 1] : (i > 0 ? _items[i - 1] : null);
    setState(() {
      _selected = next?.id;
      _selectedBooks = _books(next);
      _detail = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
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

  void _activate(LibraryItem item) {
    switch (item) {
      case SeriesItem(:final series) when tab == LibraryTab.collections && series.name == favouritesCollection:
        showFavourites();
      case SeriesItem(:final series):
        setState(() {
          _seriesSelected = item.id;
          _series = series.id;
          _selected = BookItem(series.next).id;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      case FolderItem(:final folder):
        _openFolder(folder.path, root: folder.root?.path ?? _folderRoot);
        _autoFirst = true;
      case BookItem(:final book):
        read(book);
      case BookmarkItem(:final bookmark, :final book):
        // Without a panel, guided view shows the page whole.
        read(book, at: (page: bookmark.page, panel: bookmark.panel ?? pageStart));
    }
  }

  /// Runs a change to a bookmark of [book] in the index, then writes the
  /// book's sidecar, so it travels.
  Future<void> _bookmarkChanged(LibraryBook book, Future<void> Function() change) async {
    try {
      await change();
      await ref.read(sidecarSyncProvider).writeBeside(book.path, book.key, folder: book.isFolder);
    } catch (e) {
      debugPrint('Could not change the bookmark: $e');
    }
  }

  Future<void> _editNote(LibraryBook book, BookmarkInfo bookmark) async {
    final note = await askBookmarkNote(context, bookmark);
    if (note == null) return;
    String? fresh;
    await _bookmarkChanged(book, () async => fresh = await ref.read(libraryStoreProvider).setNote(bookmark.id, note));
    // The note gives the bookmark a new id: keep it selected.
    if (fresh != null && mounted && _selected == 'm:${bookmark.id}') setState(() => _selected = 'm:$fresh');
  }

  void read(LibraryBook book, {Place? at}) => ref.read(readerProvider.notifier).open(book.path, at: at);

  /// A tap: selects, and a second tap on the selected cover opens it. On a
  /// phone-sized screen a tap on a book shows its detail page.
  void _tap(LibraryItem item, {required bool wide}) {
    _autoFirst = false;
    if (item is BookItem && !wide) {
      setState(() {
        _selected = item.id;
        _detail = true;
      });
      return;
    }
    if (_selected == item.id || item is SeriesItem || item is FolderItem) {
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

  List<LibraryItem> _itemsFor(List<LibraryBook> books, List<RootInfo> roots, List<BookmarkInfo> bookmarks) {
    final q = _query.trim();
    switch (tab) {
      case LibraryTab.reading:
        final started = books.where((b) => b.started && b.matches(q)).toList()
          ..sort((a, b) {
            if (a.finished != b.finished) return a.finished ? 1 : -1;
            return (b.readAt ?? DateTime(0)).compareTo(a.readAt ?? DateTime(0));
          });
        return [for (final b in started) BookItem(b)];
      case LibraryTab.collections when _favourites:
        final favourites = collectionGroups(books).where((s) => s.name == favouritesCollection).firstOrNull;
        return [
          for (final b in favourites?.books ?? const <LibraryBook>[])
            if (b.matches(q)) BookItem(b),
        ];
      case LibraryTab.series || LibraryTab.collections:
        final all = _groups(books);
        final open = all.where((s) => s.id == _series).firstOrNull;
        if (open != null) return [for (final b in open.books.where((b) => b.matches(q))) BookItem(b)];
        return [
          for (final s in all.where((s) => s.matches(q)))
            s.books.length == 1 && tab == LibraryTab.series ? BookItem(s.books.first) : SeriesItem(s),
        ];
      case LibraryTab.books:
        return [
          for (final s in LibrarySeries.group(books))
            for (final b in s.books)
              if (b.matches(q)) BookItem(b),
        ];
      case LibraryTab.folders:
        if (_folder == null) {
          return [
            for (final f in LibraryFolder.roots(roots, books))
              if (f.matches(q)) FolderItem(f),
          ];
        }
        final (:folders, books: here) = LibraryFolder.children(_folder!, books);
        return [
          for (final f in folders)
            if (f.matches(q)) FolderItem(f),
          for (final b in here)
            if (b.matches(q)) BookItem(b),
        ];
      case LibraryTab.history:
        return const [];
      case LibraryTab.bookmarks:
        final byBook = <String, List<BookmarkInfo>>{};
        for (final m in bookmarks) {
          (byBook[m.contentKey] ??= []).add(m);
        }
        final lower = q.toLowerCase();
        // Book by book in the order of the Books tab, each in reading order.
        return [
          for (final s in LibrarySeries.group(books))
            for (final b in s.books)
              for (final m in byBook[b.key] ?? const <BookmarkInfo>[])
                if (b.matches(q) || (m.note?.toLowerCase().contains(lower) ?? false)) BookmarkItem(m, b),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(booksProvider).value ?? const <LibraryBook>[];
    final roots = ref.watch(rootsProvider).value;
    // Open on what you are reading when there is something; else the series.
    _tab ??= roots == null ? null : (books.any((b) => b.inProgress) ? LibraryTab.reading : LibraryTab.series);
    // A library folder taken out of the library while we are in it. One
    // just added may not be in the list yet.
    if (_folderRoot != null && roots != null) {
      if (roots.any((r) => r.path == _folderRoot)) {
        _rootListed = true;
      } else if (_rootListed) {
        _folder = _folderRoot = null;
      }
    }
    // The folder shown was deleted or emptied on disk: up to the nearest
    // folder above that still holds books, as a file manager would.
    // Not while the books are still loading or a scan may be adding them: a
    // folder opened at start has none yet.
    final settled = ref.watch(booksProvider).hasValue && !(ref.watch(scanStatusProvider).value?.running ?? true);
    while (settled && _folder != null && _folder != _folderRoot && !books.any((b) => p.isWithin(_folder!, b.path))) {
      _folder = p.dirname(_folder!);
      _selected = null;
      _detail = false;
    }
    final bookmarks = tab == LibraryTab.bookmarks
        ? ref.watch(allBookmarksProvider).value ?? const <BookmarkInfo>[]
        : const <BookmarkInfo>[];
    _items = _itemsFor(books, roots ?? const [], bookmarks);
    // A folder just opened: its first item, even as a scan adds more.
    if (_autoFirst && _items.isNotEmpty) _selected = _items.first.id;
    if (_selected != null && !_items.any((it) => it.id == _selected)) {
      // An edit moved the book to another series, or renamed its series:
      // the selection follows the books.
      _selected = _items.where((it) => _books(it).any(_selectedBooks.contains)).firstOrNull?.id;
    }
    _selectedBooks = _books(_selectedItem);

    final empty = roots != null && roots.isEmpty && books.isEmpty;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        final rail = box.maxWidth >= 600;
        final selectedItem = _selectedItem;
        final Widget body = empty
            ? EmptyLibrary(
                onAddRoot: widget.onAddRoot,
                onOpenFile: widget.onOpenFile,
                onOpenFolder: widget.onOpenFolder,
                onSettings: () => _showSettings(),
              )
            : _detail && !wide && selectedItem is BookItem
            ? BookDetail(
                book: selectedItem.book,
                onRead: read,
                onBack: back,
                onBeforeDelete: () => selectNeighbourOf(selectedItem.book.key),
              )
            : _detail && !wide && selectedItem is FolderItem
            ? FolderDetail(
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
                      LibraryTab.history => HistoryPane(books: books, query: _query.trim(), onRead: read),
                      LibraryTab.bookmarks => _bookmarkRows(context),
                      _ => _grid(context, wide),
                    },
                  ),
                ],
              );
        final Widget? pane = !wide || empty || _listTab
            ? null
            : switch (selectedItem) {
                BookItem(:final book) => BookDetail(
                  book: book,
                  onRead: read,
                  onBeforeDelete: () => selectNeighbourOf(book.key),
                ),
                SeriesItem(:final series) => SeriesDetail(
                  series: series,
                  onRead: read,
                  canRename: tab == LibraryTab.series,
                ),
                FolderItem(:final folder) => FolderDetail(
                  folder: folder,
                  onOpen: () => _activate(selectedItem),
                  onRead: read,
                ),
                BookmarkItem(:final book) => BookDetail(
                  book: book,
                  onRead: read,
                  onBeforeDelete: () => selectNeighbourOf(book.key),
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
                    // Scrolls when the tabs do not fit: a short window, or
                    // large text.
                    LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          child: IntrinsicHeight(
                            child: NavigationRail(
                              selectedIndex: tab.index,
                              labelType: NavigationRailLabelType.all,
                              onDestinationSelected: (i) => _setTab(LibraryTab.values[i]),
                              destinations: [
                                for (final t in LibraryTab.values)
                                  NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(child: body),
                  if (pane != null) ...[const VerticalDivider(width: 1), SizedBox(width: 380, child: pane)],
                ],
              ),
            ),
            LibraryStatus(books: books, pending: widget.pending, onFailures: () => _showFailures(context)),
          ],
        );
        return Scaffold(
          body: SafeArea(child: content),
          bottomNavigationBar: rail || empty
              ? null
              : NavigationBar(
                  selectedIndex: tab.index,
                  // Seven tabs leave no room for every label on a phone.
                  labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
                  onDestinationSelected: (i) => _setTab(LibraryTab.values[i]),
                  destinations: [
                    for (final t in LibraryTab.values)
                      NavigationDestination(icon: Icon(t.icon), label: t.short, tooltip: t.label),
                  ],
                ),
        );
      },
    );
  }

  Widget _header(BuildContext context, List<LibraryBook> books) {
    final theme = Theme.of(context);
    final series = _series == null ? null : _groups(books).where((s) => s.id == _series).firstOrNull;
    // A phone's header is tight: smaller buttons, and gs alone reshuffles.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final row = Padding(
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
          ] else if (tab == LibraryTab.collections && _favourites) ...[
            IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back to collections', onPressed: back),
            Flexible(
              child: Text(favouritesCollection, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
          ] else if (tab == LibraryTab.folders && _folder != null) ...[
            IconButton(
              key: const Key('folderUp'),
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Up a folder (Esc)',
              onPressed: back,
            ),
            Flexible(flex: 3, child: _breadcrumb(theme)),
            const SizedBox(width: 12),
          ] else if (!narrow) ...[
            // A phone's bottom tabs name the tab already.
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
            key: const Key('favourites'),
            icon: Icon(_favourites && tab == LibraryTab.collections ? Icons.star : Icons.star_outline),
            tooltip: 'Favourites (gf)',
            onPressed: showFavourites,
          ),
          IconButton(
            key: const Key('addRoot'),
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Add a folder to the library (A)',
            onPressed: widget.onAddRoot,
          ),
          if (tab == LibraryTab.folders) ...[
            IconButton(
              key: const Key('shuffle'),
              icon: Icon(_shuffle ? Icons.shuffle_on_outlined : Icons.shuffle),
              isSelected: _shuffle,
              tooltip: _shuffle ? 'Show covers again (S)' : 'Shuffle: a random page of each comic (S)',
              onPressed: () => setShuffle(!_shuffle),
            ),
            if (_shuffle && !narrow)
              IconButton(
                key: const Key('reshuffle'),
                icon: const Icon(Icons.casino_outlined),
                tooltip: 'Other random pages (gs)',
                onPressed: () => setState(_reshuffle),
              ),
          ],
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
            onPressed: () => _showSettings(),
          ),
        ],
      ),
    );
    if (!narrow) return row;
    return IconButtonTheme(
      data: IconButtonThemeData(style: IconButton.styleFrom(visualDensity: VisualDensity.compact)),
      child: row,
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

  static const _bookmarkRowHeight = 76.0;

  /// The Bookmarks tab: every bookmark and mark in the library, book by
  /// book. A tap opens the book there; `e` writes a note, `x` removes.
  Widget _bookmarkRows(BuildContext context) {
    final theme = Theme.of(context);
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.isNotEmpty
                ? 'Nothing matches "$_query".'
                : 'No bookmarks yet. In the reader, mm or the bookmark button bookmarks the page, '
                      'or the panel in guided view.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        _cols = 1;
        _rowExtent = _bookmarkRowHeight;
        _viewport = box.maxHeight;
        return ListView.builder(
          key: const Key('bookmarksTab'),
          controller: _scroll,
          itemExtent: _bookmarkRowHeight,
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final item = _items[i] as BookmarkItem;
            final m = item.bookmark;
            final selected = item.id == _selected;
            return Container(
              decoration: BoxDecoration(
                border: selected ? Border.all(color: Colors.amber, width: 3) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: ListTile(
                key: Key('bookmarkItem-$i'),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(width: 36, height: 54, child: CoverImage(bookKey: item.book.key, width: 96)),
                ),
                title: Text(item.book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    '${m.mark == null ? '' : "Mark '${m.mark}, "}${describePlace(m)}',
                    if (m.note != null) m.note!,
                  ].join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  setState(() => _selected = item.id);
                  _activate(item);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_note),
                      tooltip: 'Note (e)',
                      onPressed: () => _editNote(item.book, m),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove (x)',
                      onPressed: () =>
                          _bookmarkChanged(item.book, () => ref.read(libraryStoreProvider).deleteBookmark(m.id)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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
          : tab == LibraryTab.collections && _favourites
          ? 'No favourites yet. * on a comic, in the reader or on its cover here, adds it; so does the star in its details.'
          : tab == LibraryTab.collections
          ? 'No collections yet. Open a book\'s details and add it to one.'
          : 'No books found yet.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        const pad = 12.0, gap = 12.0;
        _cols = math.max(2, (box.maxWidth - pad * 2 + gap) ~/ (160 + gap));
        final itemW = (box.maxWidth - pad * 2 - gap * (_cols - 1)) / _cols;
        final extent = itemW * 1.5 + 48;
        _rowExtent = extent + gap;
        _viewport = box.maxHeight;
        final shuffle = _shuffle && tab == LibraryTab.folders;
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
            return CoverCard(
              item: item,
              shufflePage: shuffle && item is BookItem ? shufflePage(item.book.key, item.book.pageCount, _seed) : null,
              selected: item.id == _selected,
              onTap: () => _tap(item, wide: wide),
              onLongPress: () => setState(() {
                _selected = item.id;
                _detail = item is BookItem || item is FolderItem;
              }),
            );
          },
        );
      },
    );
  }
}
