import 'dart:async';
import 'dart:math' as math;

import 'package:comic_formats/comic_formats.dart' show naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import '../data/settings_store.dart';
import '../grid_zoom.dart';
import '../hotkeys.dart';
import '../reader/bookmark_list.dart';
import '../reader/guided.dart';
import '../reader/reader_notifier.dart';
import '../reader/recent_books.dart';
import '../undo_notice.dart';
import 'book_detail.dart';
import 'bulk_actions.dart';
import 'cover_card.dart';
import 'default_folder.dart';
import 'edit_dialog.dart';
import 'folder_filter.dart';
import 'folder_filter_dialog.dart';
import 'library_items.dart';
import 'library_panes.dart';
import 'library_status.dart';
import 'library_store.dart';
import 'move_books.dart';
import 'providers.dart';
import 's3_actions.dart';
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
    this.onContinue,
    this.onRescan,
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

  /// Opens the comic read last where it was left (`C`).
  final VoidCallback? onContinue;

  /// Scans the library folders and watches them anew, after a folder came
  /// back into the library (the Undo of taking it out).
  final Future<void> Function()? onRescan;

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

class LibraryScreenState extends ConsumerState<LibraryScreen> implements CoverSizer {
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

  /// Books marked for an action on several (Shift+arrows, `V`, Ctrl+A,
  /// Ctrl/Shift+click, Select), by content key.
  final _marked = <String>{};

  /// Where the run of Shift+arrows or Shift+clicks started (an item id),
  /// and the marks there were before it: the run marks every comic from
  /// here to the selection, on top of those.
  String? _anchor;
  Set<String> _beforeRun = const {};

  /// Taps mark rather than open: the Select button on a phone.
  bool _selecting = false;

  // Grid geometry from the last layout, for keyboard movement.
  int _cols = 2;
  double _rowExtent = 300;
  double _viewport = 600;
  List<LibraryItem> _items = const [];

  /// Shuffle on the tabs of covers (`S`): random pages instead of covers,
  /// picked by [_seed].
  bool _shuffle = false;
  int _seed = 0;
  final _random = math.Random();

  /// The Folders tab's filter by type, size and date (`F`), kept across
  /// restarts.
  FolderFilter _filter = FolderFilter.none;

  /// How wide a cover aims to be, in logical pixels: the cover grids' zoom
  /// (`+` `-`, Ctrl and the wheel, a pinch), one size for every tab of
  /// covers, kept across restarts. Null for the default.
  double? _coverTarget;

  /// The default cover width, and the steps and limits of the zoom
  /// ([GridZoom.covers]: 72 to 480 px).
  /// The cover files are 512 pixels wide, so a cover sized by hand
  /// ([coverDecodeWidth]) is sharp up to 512 device pixels: all the way
  /// on a screen of one pixel a point, to 256 px on a 2x one and about
  /// 170 px on a 3x phone. Bigger than that it is the same picture scaled
  /// up, and soft. (Covers of the usual size are decoded 400 pixels wide
  /// on every screen, [usualCoverDecodeWidth].) The
  /// limit is not lowered on such screens for it: big covers are asked
  /// for to see them big, soft or not, and sharper files would mean
  /// making every cover in the library and on S3 again (the guide says
  /// where they turn soft).
  static const _defaultCover = 160.0;
  static const _coverGap = GridZoom.coversGap;
  static const _coverPad = 12.0;
  static const _coverZoom = GridZoom.covers;

  /// The cover grid's width inside its padding at the last layout.
  double _inner = 0;

  /// Ctrl and the wheel and the pinch; it knows when a touch was a pinch.
  final _zoomArea = GlobalKey<GridZoomAreaState>();

  @override
  void initState() {
    super.initState();
    unawaited(_loadCoverSize());
    unawaited(
      ref
          .read(settingsStoreProvider)
          .loadBool(SettingsStore.shuffle)
          .then((on) {
            if (on == true && mounted) setState(() => _shuffle = true);
          })
          .catchError((Object e) => debugPrint('Could not read the shuffle setting: $e')),
    );
    unawaited(
      ref
          .read(settingsStoreProvider)
          .loadString(SettingsStore.folderFilter)
          .then((text) {
            if (mounted) setState(() => _filter = FolderFilter.decode(text));
          })
          .catchError((Object e) => debugPrint('Could not read the folder filter: $e')),
    );
    _reshuffle();
  }

  /// Takes up the saved cover size; unset, or anything that is no width
  /// ([SettingsStore.parseSize]: a settings file edited by hand), is the
  /// default. So is the default width itself, [_defaultCover], which only
  /// a file written by hand or by another program holds (the app saves
  /// the usual size as no setting): it means the usual size, with its
  /// pictures and its two covers a row at least, not a size set by hand
  /// that happens to be as wide. The setting is left as it was read.
  Future<void> _loadCoverSize() async {
    try {
      final kept = SettingsStore.parseSize(await ref.read(settingsStoreProvider).loadString(SettingsStore.coverSize));
      final target = kept == _defaultCover ? null : kept;
      if (mounted && target != _coverTarget) setState(() => _coverTarget = target);
    } catch (e) {
      debugPrint('Could not read the cover size: $e');
    }
  }

  /// The grid of covers is on screen: a tab of covers with something on
  /// it, and no details page over it (a phone-wide window). Only then is
  /// there anything to size, and a width to work the columns out from.
  bool get _coversShown => _zoomArea.currentState != null && _inner > 0;

  /// The covers a row for the size asked for, in a grid [inner] wide:
  /// the usual ones, or zoomed, what the size asked for gives.
  int _columnsIn(double inner) => switch (_coverTarget) {
    null => usualCoverColumns(inner),
    final target => _coverZoom.columns(inner, target),
  };

  /// The covers a row at the usual size in a grid [inner] wide: as many
  /// 160 px covers as fit, and never one a row, however narrow the window.
  /// Exactly what it was before covers could be sized, at every width
  /// ([GridZoom.fitting], without the allowance a kept size needs).
  @visibleForTesting
  static int usualCoverColumns(double inner) => math.max(2, _coverZoom.fitting(inner, _defaultCover));

  /// What Settings' Cover size line shows (covers a row, bigger and smaller
  /// possible, sized by hand), as of the last frame: the line listens to
  /// it, so it follows a window made wider, the first comics of a scan and
  /// a `+` from elsewhere while Settings is open.
  final _sizerState = ValueNotifier<(int?, bool, bool, bool)>((null, false, false, false));
  bool _sizerDue = false;

  /// After this frame, tells whoever listens what the cover size line
  /// should say now. Called from every build and layout, where it can
  /// change; told after the frame, since a listener rebuilds and nothing
  /// may be marked for that while the frame is built.
  void _tellSizer() {
    if (_sizerDue) return;
    _sizerDue = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sizerDue = false;
      if (mounted) _sizerState.value = (coversPerRow, canGrowCovers, canShrinkCovers, coversZoomed);
    });
  }

  @override
  void addListener(VoidCallback listener) => _sizerState.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _sizerState.removeListener(listener);

  // CoverSizer, for Settings' Cover size buttons: the same steps as the
  // keys, with the same limits. Worked out from the size asked for and not
  // from [_cols], which only follows at the next layout.
  @override
  int? get coversPerRow => _coversShown ? _columnsIn(_inner) : null;
  @override
  bool get canGrowCovers => _coversShown && _columnsIn(_inner) > _coverZoom.fewest(_inner);
  @override
  bool get canShrinkCovers => _coversShown && _columnsIn(_inner) < _coverZoom.most(_inner);
  @override
  bool get coversZoomed => _coverTarget != null;

  /// Bigger covers (fewer columns) for [by] > 0, smaller for [by] < 0.
  @override
  void zoomCovers(int by) {
    if (_coversShown) _setCoverColumns(_columnsIn(_inner) - by);
  }

  /// The usual cover size again (`=`).
  @override
  void resetCovers() => _setCoverColumns(0, reset: true);

  /// Shows [columns] covers a row, within what the width allows; [reset]
  /// goes back to the default size. What is kept is the cover width that
  /// gives, so a wider window later fits more covers of that size. The
  /// columns the usual size gives at this width are the usual size, as
  /// `=` leaves it (no size kept, the setting unset): `+` and then `-`
  /// changes nothing, not the pictures' decoded width and not what the
  /// Usual size button offers either. At the
  /// smallest or biggest already, nothing changes and nothing is saved;
  /// nor while the covers are not on screen (a list tab, an empty one, a
  /// phone's details page), where a key would change a size nobody sees.
  void _setCoverColumns(int columns, {bool reset = false}) {
    if (!_coversShown) return;
    final next = _coverZoom.clamp(_inner, columns);
    if (reset ? _coverTarget == null : next == _columnsIn(_inner)) return;
    final usual = reset || next == usualCoverColumns(_inner);
    final target = usual ? null : _coverZoom.tileWidth(_inner, next);
    final keep = _keptInView();
    setState(() => _coverTarget = target);
    unawaited(
      ref
          .read(settingsStoreProvider)
          .saveString(SettingsStore.coverSize, target == null ? null : SettingsStore.sizeText(target))
          .catchError((Object e) => debugPrint('Could not save the cover size: $e')),
    );
    // The rows moved: back to the cover that was looked at.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAgain(keep);
    });
  }

  /// The cover a zoom must leave in view: the selected one when it shows,
  /// else the first of the row along the top.
  int _keptInView() {
    if (!_scroll.hasClients) return 0;
    final at = _scroll.position.pixels;
    final first = (at ~/ _rowExtent) * _cols;
    final i = _items.indexWhere((it) => it.id == _selected);
    final shown = i >= first && (i ~/ _cols) * _rowExtent < at + _scroll.position.viewportDimension;
    return shown ? i : first;
  }

  /// After a zoom: the row of cover [i] in view again, along the top when
  /// it is not the selected one (whose row only has to show).
  void _showAgain(int i) {
    if (!_scroll.hasClients || _items.isEmpty) return;
    final selected = _items.indexWhere((it) => it.id == _selected);
    if (i == selected) return _reveal();
    final top = (i.clamp(0, _items.length - 1) ~/ _cols) * _rowExtent;
    _scroll.jumpTo(top.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  bool get shuffle => _shuffle;

  FolderFilter get filter => _filter;

  /// Filters the Folders tab, remembered for the next start.
  void setFilter(FolderFilter f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _selected = null;
    });
    unawaited(
      ref
          .read(settingsStoreProvider)
          .saveString(SettingsStore.folderFilter, f.encode())
          .catchError((Object e) => debugPrint('Could not save the folder filter: $e')),
    );
  }

  /// The filter's dialog, offering the formats the library has.
  Future<void> _openFilter() async {
    final books = ref.read(booksProvider).value ?? const <LibraryBook>[];
    await showFolderFilter(
      context,
      filter: _filter,
      formats: {for (final b in books) b.format}.toList(),
      onChanged: setFilter,
    );
    widget.keysFocus?.requestFocus();
  }

  /// `g,`, the header's cog or the empty library's button. One at a time:
  /// the key still reaches the library while the dialog is on its way.
  Future<void> _showSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      await showSettings(
        context,
        covers: this,
        onExportSidecars: widget.onExportSidecars,
        onExportSettings: widget.onExportSettings,
        onImportSettings: widget.onImportSettings,
      );
    } finally {
      _settingsOpen = false;
    }
  }

  bool _settingsOpen = false;

  /// Takes up the saved cover size, filter and shuffle setting again,
  /// after an import changed them.
  Future<void> reloadSettings() async {
    await _loadCoverSize();
    try {
      final filter = FolderFilter.decode(await ref.read(settingsStoreProvider).loadString(SettingsStore.folderFilter));
      if (mounted) setState(() => _filter = filter);
    } catch (e) {
      debugPrint('Could not read the folder filter: $e');
    }
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
    _sizerState.dispose();
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

    // Shift+arrows: the selection moves and every comic between where the
    // run started and it is marked.
    void extend(int Function(int from) to) {
      if (n == 0) return;
      final from = index();
      final i = from == null ? 0 : to(from).clamp(0, n - 1).toInt();
      _startRun(from ?? 0);
      _markRun(i);
      _select(i);
    }

    final marking = _markingIntents.contains(c.intent);
    if (!marking) _anchor = null;
    // With comics marked, these act on all of them.
    final marked = _markedBooks();

    if (_buttonKeys(c, marked)) return true;
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
      case ReaderIntent.markLeft:
        extend((i) => i - c.times);
      case ReaderIntent.markRight:
        extend((i) => i + c.times);
      case ReaderIntent.markUp:
        extend((i) => i - _cols * c.times);
      case ReaderIntent.markDown:
        extend((i) => i + _cols * c.times);
      case ReaderIntent.markToFirst:
        extend((_) => 0);
      case ReaderIntent.markToLast:
        extend((_) => n - 1);
      case ReaderIntent.markAll:
        _markAll();
      case ReaderIntent.toggleFavourite when marked.isNotEmpty:
        unawaited(_bulk(() => toggleFavourites(context, ref, marked)));
      // In the Favourites x is * on the selected comic: out, with an Undo.
      case ReaderIntent.toggleFavourite:
      case ReaderIntent.remove when _favourites && marked.isEmpty:
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
      // The page's zoom keys size the covers here, as in the page grid.
      case ReaderIntent.zoomIn when _coverTab:
        zoomCovers(c.times);
      case ReaderIntent.zoomOut when _coverTab:
        zoomCovers(-c.times);
      case ReaderIntent.zoomReset when _coverTab:
        resetCovers();
      case ReaderIntent.toggleShuffle when _coverTab:
        setShuffle(!_shuffle);
      case ReaderIntent.reshuffle when _coverTab && _shuffle:
        setState(_reshuffle);
      case ReaderIntent.resetBook when marked.isNotEmpty:
        unawaited(_bulk(() => resetBooks(context, ref, marked)));
      case ReaderIntent.deleteBook when marked.isNotEmpty:
        unawaited(_bulk(() => _deleteMarked(marked)));
      case ReaderIntent.filterFolders when tab == LibraryTab.folders:
        unawaited(_openFilter());
      case ReaderIntent.resetBook:
        if (_selectedItem case BookItem(:final book) when !book.remoteOnly) {
          unawaited(resetBook(context, ref, book).whenComplete(() => widget.keysFocus?.requestFocus()));
        }
      case ReaderIntent.deleteBook:
        if (_selectedItem case BookItem(:final book) when book.remoteOnly) {
          // Nothing here to delete: taking it off S3 is what is left.
          unawaited(_s3Action(() => removeBooksFromS3(context, ref, [book])));
        } else if (_selectedItem case BookItem(:final book)) {
          unawaited(
            deleteLibraryBook(
              context,
              ref,
              book,
              beforeDelete: () => selectNeighbourOf(book.key),
            ).whenComplete(() => widget.keysFocus?.requestFocus()),
          );
        }
      case ReaderIntent.markBook:
        if (_selectedItem case BookItem(:final book)) {
          _toggleMark(book);
          move(1);
        }
      case ReaderIntent.moveBooks:
        final books = _markedOrSelected(marked);
        if (books.isNotEmpty) unawaited(_bulk(() => _moveBooks(books)));
      case ReaderIntent.addToCollection:
        final books = _markedOrSelected(marked);
        if (books.isNotEmpty) unawaited(_bulk(() => addBooksToCollection(context, ref, books)));
      case ReaderIntent.uploadToS3:
        final books = _actOn();
        if (books.isNotEmpty) unawaited(_s3Action(() => uploadBooks(context, ref, books)));
      case ReaderIntent.removeFromS3:
        final books = _actOn();
        if (books.isNotEmpty) unawaited(_s3Action(() => removeBooksFromS3(context, ref, books)));
      case ReaderIntent.showDetails:
        if (_selectedItem case BookItem(:final book) when !book.remoteOnly) {
          unawaited(showBookDetails(context, ref, book).whenComplete(() => widget.keysFocus?.requestFocus()));
        }
      case ReaderIntent.editBook:
        final done = widget.keysFocus?.requestFocus;
        switch (_selectedItem) {
          case BookItem(:final book) when !book.remoteOnly:
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

  /// The keys task 263 gave to buttons that had none, and `x` in an open
  /// collection: true when [c] was one of them. (`u`, the notice's Undo,
  /// is HomeScreen's: it works over an open comic too.)
  bool _buttonKeys(ReaderCommand c, List<LibraryBook> marked) {
    switch (c.intent) {
      case ReaderIntent.remove when _openCollection != null && (marked.isNotEmpty || !_favourites):
        // With comics marked, all of them, like the other keys of the
        // marks; else the selected one.
        final collection = _openCollection!;
        if (marked.isNotEmpty) {
          unawaited(_bulk(() => takeOutOfCollection(context, ref, marked, collection)));
        } else if (_selectedItem case BookItem(:final book)) {
          unawaited(_takeOutOfCollection(book, collection));
        }
      case ReaderIntent.downloadFromS3:
        final books = _actOn().where((b) => b.remoteOnly).toList();
        if (books.isNotEmpty) unawaited(_s3Action(() => downloadBooks(context, ref, books)));
      case ReaderIntent.removeRoot:
        if (_selectedItem case FolderItem(:final folder)) {
          if (folder.root case final root?) unawaited(_removeRoot(root.id, root.path));
        }
      case ReaderIntent.showScanFailures:
        _showFailures(context);
      case ReaderIntent.showSettings:
        unawaited(_showSettings());
      default:
        return false;
    }
    return true;
  }

  /// The collection whose comics are shown (the Favourites are one), null
  /// on any other screen.
  String? get _openCollection {
    if (tab != LibraryTab.collections) return null;
    if (_favourites) return favouritesCollection;
    if (_series == null) return null;
    final books = ref.read(booksProvider).value ?? const <LibraryBook>[];
    return _groups(books).where((s) => s.id == _series).firstOrNull?.name;
  }

  /// Esc: closes the detail page, then clears the search, then leaves the
  /// series or goes up a folder. False when there is nothing left to back
  /// out of.
  bool back() {
    if (_marked.isNotEmpty || _selecting) {
      _clearMarks();
    } else if (_detail) {
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

  /// `gA`, or the button in a library folder's details: out of the
  /// library, its files left alone, and said in a notice, since by key
  /// nothing else shows that it happened but a cover gone. The notice
  /// offers it back (Undo, `u`): two keys take a whole folder of comics
  /// off the shelves, and nothing asks first. Putting it back adds the
  /// folder again and scans it, which finds what was there; positions,
  /// bookmarks and collections were never gone, they go by the comics'
  /// content.
  Future<void> _removeRoot(int id, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    final undoLabel = KeyHints.tip(context, 'Undo', ReaderIntent.undo);
    final store = ref.read(libraryStoreProvider), settings = ref.read(settingsStoreProvider);
    final scanner = ref.read(scannerProvider);
    final rescan = widget.onRescan;
    final remembered = await removeLibraryFolder(store, settings, id, path);
    ref
        .read(undoNoticeProvider)
        .show(
          messenger,
          '${p.basename(path)} taken out of the library; its comics stay on disk',
          label: undoLabel,
          // Said in a notice when it throws (the folder gone from the
          // disk meanwhile, the index refusing).
          failed: 'Could not put ${p.basename(path)} back in the library',
          undo: () async {
            await restoreLibraryFolder(store, settings, path, forget: remembered);
            // HomeScreen's rescan also watches the folder again.
            await (rescan?.call() ?? scanner.scan());
          },
        );
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
    final undoLabel = KeyHints.tip(context, 'Undo', ReaderIntent.undo);
    final done = await setFavourite(ref, book, on);
    if (!done) {
      showNotice(messenger, 'Could not change the favourites for ${book.name}');
      return;
    }
    if (on) {
      showNotice(messenger, '${book.name} added to Favourites');
      return;
    }
    // With the undo key (u) as well as the button.
    ref
        .read(undoNoticeProvider)
        .show(
          messenger,
          '${book.name} taken out of Favourites',
          label: undoLabel,
          failed: 'Could not put ${book.name} back in Favourites',
          undo: () async {
            // The index refusing is a failure to tell, like anything thrown.
            if (!await setFavourite(ref, book, true)) throw StateError('the index refused');
          },
        );
  }

  /// `x` on a comic in an open collection (the Favourites have their own
  /// rule above): the next comic is selected, and [takeOutOfCollection]
  /// takes this one out with a notice that offers it back. Before task 263
  /// only the x on the chip in the comic's details did this, which no key
  /// reached.
  Future<void> _takeOutOfCollection(LibraryBook book, String collection) async {
    final i = _items.indexWhere((it) => it.id == _selected);
    if (i >= 0) {
      final next = i + 1 < _items.length ? _items[i + 1] : (i > 0 ? _items[i - 1] : null);
      setState(() => _selected = next?.id);
    }
    await takeOutOfCollection(context, ref, [book], collection);
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
    if (top < pos.pixels || _rowExtent > pos.viewportDimension) {
      // Above the screen, or a row taller than the screen (covers zoomed
      // right in, in a low window): it shows from its top.
      to = top;
    } else if (top + _rowExtent > pos.pixels + pos.viewportDimension) {
      to = top + _rowExtent - pos.viewportDimension + 16;
    }
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

  void read(LibraryBook book, {Place? at}) {
    // On S3 only: its page, with the Download button.
    if (book.remoteOnly) {
      setState(() {
        _selected = BookItem(book).id;
        _detail = true;
      });
      return;
    }
    unawaited(ref.read(readerProvider.notifier).open(book.path, at: at));
  }

  void _toggleMark(LibraryBook book) => setState(() {
    if (!_marked.remove(book.key)) _marked.add(book.key);
  });

  void _clearMarks() => setState(() {
    _marked.clear();
    _selecting = false;
    _anchor = null;
  });

  /// The intents that carry a run of marks on rather than end it.
  static const _markingIntents = {
    ReaderIntent.markLeft,
    ReaderIntent.markRight,
    ReaderIntent.markUp,
    ReaderIntent.markDown,
    ReaderIntent.markToFirst,
    ReaderIntent.markToLast,
  };

  /// Starts a run of marks at the item [i], unless one is going on.
  void _startRun(int i) {
    if (_anchor != null && _items.any((it) => it.id == _anchor)) return;
    _anchor = _items[i].id;
    _beforeRun = {..._marked};
  }

  /// Marks every comic from the run's start to the item [to], on top of
  /// the marks from before the run; one the run went past and came back
  /// from is unmarked again, as in a file manager. Folders and series in
  /// between are passed over.
  void _markRun(int to) {
    final from = _items.indexWhere((it) => it.id == _anchor);
    if (from < 0) return;
    final (lo, hi) = from <= to ? (from, to) : (to, from);
    setState(() {
      _marked
        ..clear()
        ..addAll(_beforeRun);
      for (final it in _items.sublist(lo, hi + 1)) {
        if (it is BookItem) _marked.add(it.book.key);
      }
    });
  }

  /// Ctrl+A, or Mark all in the marks bar: every comic shown, or none of
  /// them when they are all marked already.
  void _markAll() {
    final shown = [
      for (final it in _items)
        if (it is BookItem) it.book.key,
    ];
    setState(() {
      _anchor = null;
      if (shown.isNotEmpty && shown.every(_marked.contains)) {
        _marked.removeAll(shown);
      } else {
        _marked.addAll(shown);
      }
    });
  }

  /// The marked books still in the library, in the order of their paths.
  List<LibraryBook> _markedBooks() {
    if (_marked.isEmpty) return const [];
    final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
    // A comic with copies is the copy shown, so a move or a delete in a
    // folder acts on the file in that folder.
    final shown = {
      for (final it in _items.reversed)
        if (it is BookItem && _marked.contains(it.book.key)) it.book.key: it.book,
    };
    return [
      for (final b in all)
        if (_marked.contains(b.key)) shown[b.key] ?? b,
    ]..sort((a, b) => naturalCompare(a.path, b.path));
  }

  /// Runs an action on the marked books; the marks go once it went ahead.
  Future<void> _bulk(Future<bool> Function() action) async {
    final done = await action();
    if (!mounted) return;
    if (done) _clearMarks();
    widget.keysFocus?.requestFocus();
  }

  /// Deletes the marked books; the selection moves to the first cover after
  /// the last of them that stays.
  Future<bool> _deleteMarked(List<LibraryBook> books) {
    final keys = {for (final b in books) b.key};
    return deleteLibraryBooks(
      context,
      ref,
      books,
      beforeDelete: () {
        final last = _items.lastIndexWhere((it) => _books(it).any(keys.contains));
        final stays = [
          for (final it in [..._items.skip(last + 1), ..._items.take(last + 1).toList().reversed])
            if (!_books(it).every(keys.contains) || _books(it).isEmpty) it,
        ];
        setState(() {
          _selected = stays.firstOrNull?.id;
          _selectedBooks = _books(stays.firstOrNull);
          _detail = false;
        });
      },
    );
  }

  /// The books a move or a collection is for: the [marked] ones, else the
  /// selected comic's.
  List<LibraryBook> _markedOrSelected(List<LibraryBook> marked) => marked.isNotEmpty
      ? marked
      : switch (_selectedItem) {
          BookItem(:final book) when !book.remoteOnly => [book],
          _ => const [],
        };

  /// Moves [books] to a folder picked in a list, the shown folder first;
  /// the selection stays on the cover after the last of them, as a delete
  /// leaves it.
  Future<bool> _moveBooks(List<LibraryBook> books) {
    final keys = {for (final b in books) b.key};
    return moveLibraryBooks(
      context,
      ref,
      books,
      current: tab == LibraryTab.folders ? _folder : null,
      beforeMove: () {
        if (tab != LibraryTab.folders) return;
        final last = _items.lastIndexWhere((it) => _books(it).any(keys.contains));
        final stays = [
          for (final it in [..._items.skip(last + 1), ..._items.take(last + 1).toList().reversed])
            if (!_books(it).every(keys.contains) || _books(it).isEmpty) it,
        ];
        setState(() {
          _selected = stays.firstOrNull?.id;
          _selectedBooks = _books(stays.firstOrNull);
          _detail = false;
        });
      },
    );
  }

  /// The books an S3 action is for: the marked ones, else the selected
  /// cover's (a series' or folder's books too).
  List<LibraryBook> _actOn() {
    final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
    if (_marked.isNotEmpty) return all.where((b) => _marked.contains(b.key)).toList();
    final keys = _books(_selectedItem);
    return all.where((b) => keys.contains(b.key)).toList();
  }

  /// Runs an S3 action on the marks; they clear unless it was cancelled.
  Future<void> _s3Action(Future<Object?> Function() action) async {
    final done = await action();
    if (mounted && done != false) {
      _clearMarks();
      widget.keysFocus?.requestFocus();
    }
  }

  /// The bar over the grid while books are marked: how many, and what to
  /// do with all of them.
  Widget _marksBar(BuildContext context) {
    final theme = Theme.of(context);
    final marked = _markedBooks();
    final local = marked.where((b) => !b.remoteOnly).toList();
    final s3 = ref.watch(s3StatusProvider).value?.on ?? false;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    // Each names its key as the keymap has it now; a phone has no room.
    Widget button(String key, IconData icon, String label, ReaderIntent intent, VoidCallback onPressed) =>
        TextButton.icon(
          key: Key(key),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(narrow ? label : _tip(label, intent)),
        );
    return Material(
      key: const Key('marksBar'),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              marked.isEmpty
                  ? (narrow ? 'Tap covers to mark them' : 'Tap covers, or Shift+arrows, to mark them')
                  : '${marked.length} selected',
              key: const Key('marksCount'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: 4),
            button('marksAll', Icons.select_all, 'All', ReaderIntent.markAll, _markAll),
            if (local.isNotEmpty) ...[
              button(
                'marksFavourite',
                local.every((b) => b.favourite) ? Icons.star : Icons.star_outline,
                local.every((b) => b.favourite) ? 'Unfavourite' : 'Favourite',
                ReaderIntent.toggleFavourite,
                () => _bulk(() => toggleFavourites(context, ref, marked)),
              ),
              button(
                'marksMove',
                Icons.drive_file_move_outline,
                'Move',
                ReaderIntent.moveBooks,
                () => _bulk(() => _moveBooks(local)),
              ),
              button(
                'marksCollection',
                Icons.label_outline,
                'Collection',
                ReaderIntent.addToCollection,
                () => _bulk(() => addBooksToCollection(context, ref, marked)),
              ),
              button(
                'marksReset',
                Icons.restart_alt,
                'Reset',
                ReaderIntent.resetBook,
                () => _bulk(() => resetBooks(context, ref, marked)),
              ),
            ],
            if (marked.isNotEmpty)
              button(
                'marksDelete',
                Icons.delete_outline,
                'Delete',
                ReaderIntent.deleteBook,
                () => _bulk(() => _deleteMarked(marked)),
              ),
            if (s3) ..._marksS3Buttons(marked, button),
            TextButton(
              key: const Key('marksClear'),
              onPressed: _clearMarks,
              child: Text(narrow ? 'Clear' : _tip('Clear', ReaderIntent.back)),
            ),
          ],
        ),
      ),
    );
  }

  /// The marks bar's S3 buttons, each only while a marked comic can take it.
  List<Widget> _marksS3Buttons(
    List<LibraryBook> marked,
    Widget Function(String key, IconData icon, String label, ReaderIntent intent, VoidCallback onPressed) button,
  ) => [
    if (marked.any((b) => b.s3 == null))
      button(
        'marksUpload',
        Icons.cloud_upload,
        'Upload to S3',
        ReaderIntent.uploadToS3,
        () => _s3Action(() => uploadBooks(context, ref, marked)),
      ),
    if (marked.any((b) => b.remoteOnly))
      button(
        'marksDownload',
        Icons.cloud_download,
        'Download',
        ReaderIntent.downloadFromS3,
        () => _s3Action(() => downloadBooks(context, ref, marked)),
      ),
    if (marked.any((b) => b.s3 != null))
      button(
        'marksRemove',
        Icons.cloud_off,
        'Remove from S3',
        ReaderIntent.removeFromS3,
        () => _s3Action(() => removeBooksFromS3(context, ref, marked)),
      ),
  ];

  /// Under the Folders tab's header: the filter's button, and while it is
  /// on, what it lets through, each part with its own x, and a way to clear
  /// it all. A tap on a part opens the filter. Its own line, as the header
  /// has no room left beside a breadcrumb.
  Widget _filterBar(BuildContext context) {
    final f = _filter;
    return Container(
      key: const Key('filterBar'),
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.fromLTRB(8, 0, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _filterButton(f),
          if (f.formats.isNotEmpty)
            _filterPart(
              'filterBarType',
              (f.formats.map(formatLabel).toList()..sort()).join(', '),
              f.copyWith(formats: const {}),
            ),
          if (f.size != SizeRange.any) _filterPart('filterBarSize', f.size.label, f.copyWith(size: SizeRange.any)),
          if (f.date != DateRange.any)
            _filterPart('filterBarDate', 'Modified: ${f.date.label.toLowerCase()}', f.copyWith(date: DateRange.any)),
          if (f.isActive)
            Tooltip(
              message: _tip('By key: Clear all in the filter', ReaderIntent.filterFolders),
              child: TextButton(
                key: const Key('filterBarClear'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => setFilter(FolderFilter.none),
                child: const Text('Clear filter'),
              ),
            ),
        ],
      ),
    );
  }

  static const _shuffleKey = ReaderIntent.toggleShuffle;
  static const _markHelp = 'Mark comics to delete, reset, favourite or sync together';

  /// [text] with the key [intent] has now, for a tooltip or a label.
  String _tip(String text, ReaderIntent intent) => KeyHints.tip(context, text, intent);

  /// The filter line's button. Its tooltip names the key also while the
  /// label says what is filtered.
  Widget _filterButton(FolderFilter f) {
    final named = _tip('Filter by type, size, date', ReaderIntent.filterFolders);
    return Tooltip(
      message: named,
      child: TextButton.icon(
        key: const Key('filter'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        icon: Icon(f.isActive ? Icons.filter_alt : Icons.filter_alt_outlined),
        label: Text(f.isActive ? 'Filtered:' : named),
        onPressed: _openFilter,
      ),
    );
  }

  /// One part of what the filter lets through; [without] is the filter
  /// with that part off, which its x sets.
  Widget _filterPart(String key, String label, FolderFilter without) => InputChip(
    key: Key(key),
    label: Text(label),
    visualDensity: VisualDensity.compact,
    // By key the filter is changed in its dialog; the x has none of its own.
    tooltip: _tip('Change the filter', ReaderIntent.filterFolders),
    onPressed: _openFilter,
    onDeleted: () => setFilter(without),
    deleteButtonTooltipMessage: 'Take this off the filter',
  );

  /// A tap: selects, and a second tap on the selected cover opens it. On a
  /// phone-sized screen a tap on a book shows its detail page.
  void _tap(LibraryItem item, {required bool wide}) {
    _autoFirst = false;
    // Shift+click marks every comic from the run's start, or the selected
    // cover, to this one.
    if (HardwareKeyboard.instance.isShiftPressed) {
      final to = _items.indexWhere((it) => it.id == item.id);
      final from = _items.indexWhere((it) => it.id == (_anchor ?? _selected));
      if (to >= 0) {
        _startRun(from < 0 ? to : from);
        _markRun(to);
        setState(() => _selected = item.id);
        return;
      }
    }
    _anchor = null;
    if (item is BookItem && (_selecting || HardwareKeyboard.instance.isControlPressed)) {
      _toggleMark(item.book);
      setState(() => _selected = item.id);
      return;
    }
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

  /// A tab of covers, where shuffle shows: all but History and Bookmarks.
  bool get _coverTab => tab != LibraryTab.history && tab != LibraryTab.bookmarks;

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
        final now = DateTime.now();
        // A comic with copies in several folders is in each of them.
        final files = [for (final b in books) ...b.everyFile];
        final filtered = _filter.isActive ? files.where((b) => _filter.accepts(b, now)).toList() : files;
        if (_folder == null) {
          return [
            for (final f in LibraryFolder.roots(roots, filtered))
              // A library folder with nothing the filter lets through goes
              // too; without a filter an empty one stays, to be taken out.
              if (f.matches(q) && (!_filter.isActive || f.books.isNotEmpty)) FolderItem(f),
          ];
        }
        final (:folders, books: here) = LibraryFolder.children(_folder!, filtered);
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
    _tellSizer();
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
    while (settled &&
        _folder != null &&
        _folder != _folderRoot &&
        !books.expand((b) => b.everyFile).any((b) => p.isWithin(_folder!, b.path))) {
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
                marked: _marked.contains(selectedItem.book.key),
                // Back to the covers, where taps go on marking.
                onMark: () => setState(() {
                  _anchor = null;
                  _toggleMark(selectedItem.book);
                  _selecting = _marked.isNotEmpty;
                  _detail = false;
                }),
              )
            : _detail && !wide && selectedItem is FolderItem
            ? _folderDetail(selectedItem, read, onBack: back)
            : Column(
                children: [
                  _header(context, books),
                  if (_marked.isNotEmpty || _selecting) _marksBar(context),
                  if (tab == LibraryTab.folders) _filterBar(context),
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
                  marked: _marked.contains(book.key),
                  onMark: () => setState(() {
                    _anchor = null;
                    _toggleMark(book);
                    // Taps on covers go on marking, as with Select on a phone.
                    _selecting = _marked.isNotEmpty;
                  }),
                ),
                SeriesItem(:final series) => SeriesDetail(
                  series: series,
                  onRead: read,
                  canRename: tab == LibraryTab.series,
                ),
                FolderItem() => _folderDetail(selectedItem, read),
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

  /// A folder's details, in the pane beside the covers or, with [onBack],
  /// as a page of its own. Its button for a library folder goes the way
  /// of `gA` ([_removeRoot]).
  Widget _folderDetail(FolderItem item, void Function(LibraryBook, {Place? at}) read, {VoidCallback? onBack}) =>
      FolderDetail(
        folder: item.folder,
        onOpen: () => _activate(item),
        onRead: read,
        onRemoveRoot: _removeRoot,
        onBack: onBack,
      );

  /// The arrow that leaves an open series or collection; [text] says
  /// where to, and the tooltip adds the key.
  Widget _backButton(String text) =>
      IconButton(icon: const Icon(Icons.arrow_back), tooltip: _tip(text, ReaderIntent.back), onPressed: back);

  Widget _header(BuildContext context, List<LibraryBook> books) {
    final theme = Theme.of(context);
    final series = _series == null ? null : _groups(books).where((s) => s.id == _series).firstOrNull;
    // A phone's header is tight: smaller buttons, and gs alone reshuffles.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    // A small tablet in portrait (600 to 840 wide) has the rail but not the
    // room for the tab's name as well: the search box shrank to "Searc…".
    // The rail names the tab there.
    final titled = MediaQuery.sizeOf(context).width >= 840;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          if (series != null) ...[
            _backButton(tab == LibraryTab.collections ? 'Back to collections' : 'Back to series'),
            Flexible(
              child: Text(series.name, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
          ] else if (tab == LibraryTab.collections && _favourites) ...[
            _backButton('Back to collections'),
            Flexible(
              child: Text(favouritesCollection, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
          ] else if (tab == LibraryTab.folders && _folder != null) ...[
            IconButton(
              key: const Key('folderUp'),
              icon: const Icon(Icons.arrow_upward),
              tooltip: KeyHints.tip(context, 'Up a folder', ReaderIntent.back),
              onPressed: back,
            ),
            Flexible(flex: 3, child: _breadcrumb(theme)),
            const SizedBox(width: 12),
          ] else if (titled) ...[
            // A phone's bottom tabs name the tab already, a small tablet's rail too.
            Text(tab.label, style: theme.textTheme.titleLarge),
            const SizedBox(width: 16),
          ],
          Expanded(child: _searchField()),
          // On a phone, only on the Reading tab, where the app starts: the
          // Folders tab's header has no room left for it.
          if (ref.watch(recentBooksProvider).firstOrNull case final last?
              when widget.onContinue != null && (!narrow || tab == LibraryTab.reading))
            IconButton(
              key: const Key('continue'),
              icon: const Icon(Icons.play_circle_outline),
              tooltip: KeyHints.tip(context, 'Continue ${last.title}', ReaderIntent.continueReading),
              onPressed: widget.onContinue,
            ),
          IconButton(
            key: const Key('favourites'),
            icon: Icon(_favourites && tab == LibraryTab.collections ? Icons.star : Icons.star_outline),
            tooltip: KeyHints.tip(context, 'Favourites', ReaderIntent.showFavourites),
            onPressed: showFavourites,
          ),
          IconButton(
            key: const Key('addRoot'),
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: KeyHints.tip(context, 'Add a folder to the library', ReaderIntent.addRoot),
            onPressed: widget.onAddRoot,
          ),
          if (_coverTab) ...[
            IconButton(
              key: const Key('shuffle'),
              icon: Icon(_shuffle ? Icons.shuffle_on_outlined : Icons.shuffle),
              isSelected: _shuffle,
              tooltip: _tip(_shuffle ? 'Show covers again' : 'Shuffle: a random page of each comic', _shuffleKey),
              onPressed: () => setShuffle(!_shuffle),
            ),
            if (_shuffle && !narrow)
              IconButton(
                key: const Key('reshuffle'),
                icon: const Icon(Icons.casino_outlined),
                tooltip: KeyHints.tip(context, 'Other random pages', ReaderIntent.reshuffle),
                onPressed: () => setState(_reshuffle),
              ),
          ],
          if (tab == LibraryTab.folders)
            IconButton(
              key: const Key('rescan'),
              icon: const Icon(Icons.refresh),
              tooltip: KeyHints.tip(context, 'Rescan the library folders', ReaderIntent.rescan),
              onPressed: () => ref.read(scannerProvider).scan(),
            ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: KeyHints.tip(context, 'Open a comic without adding it', ReaderIntent.openFile),
            onPressed: widget.onOpenFile,
          ),
          // Wider screens have Shift and Ctrl, and Mark in the details pane or page.
          if (narrow && !_listTab && tab != LibraryTab.bookmarks)
            IconButton(
              key: const Key('select'),
              icon: Icon(_selecting ? Icons.checklist_rtl : Icons.checklist),
              isSelected: _selecting,
              tooltip: _selecting ? _tip('Stop marking', ReaderIntent.back) : _tip(_markHelp, ReaderIntent.markBook),
              onPressed: () => _selecting ? _clearMarks() : setState(() => _selecting = true),
            ),
          IconButton(
            key: const Key('settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: KeyHints.tip(context, 'Settings', ReaderIntent.showSettings),
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

  Widget _searchField() => TextField(
    key: const Key('search'),
    controller: _search,
    focusNode: _searchFocus,
    decoration: InputDecoration(
      isDense: true,
      prefixIcon: const Icon(Icons.search),
      hintText: KeyHints.tip(context, 'Search titles, series, creators', ReaderIntent.search),
      border: const OutlineInputBorder(),
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.clear),
              tooltip: KeyHints.tip(context, 'Clear the search', ReaderIntent.back),
              onPressed: () => back(),
            ),
    ),
    onChanged: (q) => setState(() {
      _query = q;
      _selected = null;
    }),
    onSubmitted: (_) {
      widget.keysFocus?.requestFocus();
      if (_items.isNotEmpty) _select(0);
    },
  );

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
          // No key of their own: Backspace goes up a folder at a time.
          Tooltip(
            message: KeyHints.tip(context, 'All library folders: up, a folder at a time', ReaderIntent.up),
            child: TextButton(onPressed: () => _openFolder(null), child: const Text('Folders')),
          ),
          for (final (i, path) in paths.indexed) ...[
            const Icon(Icons.chevron_right, size: 18),
            i == paths.length - 1
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(p.basename(path), style: theme.textTheme.titleLarge),
                  )
                : Tooltip(
                    message: KeyHints.tip(context, 'Up to ${p.basename(path)}, a folder at a time', ReaderIntent.up),
                    child: TextButton(onPressed: () => _upTo(path), child: Text(p.basename(path))),
                  ),
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

  /// The files the last scan could not read, and why: `g!` or a tap on
  /// the status line's count. With none, a notice says so.
  void _showFailures(BuildContext context) {
    final failed = ref.read(scanStatusProvider).value?.failed ?? const [];
    if (failed.isEmpty) {
      showNotice(ScaffoldMessenger.of(context), 'The last scan could read every comic');
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => DialogHotkeys(
          child: AlertDialog(
            key: const Key('failuresDialog'),
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
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Mnemonic('Close')),
            ],
          ),
        ),
      ).whenComplete(() => widget.keysFocus?.requestFocus()),
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
                      tooltip: KeyHints.tip(context, 'Note', ReaderIntent.editBook),
                      onPressed: () => _editNote(item.book, m),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: KeyHints.tip(context, 'Remove', ReaderIntent.remove),
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
      final filtered = tab == LibraryTab.folders && _filter.isActive;
      final text = _query.isNotEmpty
          ? 'Nothing matches "$_query"${filtered ? ' with this filter' : ''}.'
          : filtered
          ? (_folder == null ? 'No comics match the filter.' : 'No comics in this folder match the filter.')
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
        const pad = _coverPad, gap = _coverGap;
        final inner = _inner = box.maxWidth - pad * 2;
        _tellSizer();
        _cols = _columnsIn(inner);
        final itemW = _coverZoom.tileWidth(inner, _cols);
        final extent = itemW * 1.5 + 48;
        _rowExtent = extent + gap;
        _viewport = box.maxHeight;
        return GridZoomArea(
          key: _zoomArea,
          columns: _cols,
          onColumns: (n) {
            _setCoverColumns(n);
            return _columnsIn(_inner);
          },
          builder: (context, physics) => _covers(physics, wide: wide, extent: extent, itemW: itemW),
        );
      },
    );
  }

  /// The grid of covers, [_cols] a row, each [itemW] wide in rows [extent]
  /// high, scrolling with [physics] (null for the usual ones).
  Widget _covers(ScrollPhysics? physics, {required bool wide, required double extent, required double itemW}) {
    final shuffle = _shuffle && _coverTab;
    final sizes = coverPictureSizes(itemW * MediaQuery.devicePixelRatioOf(context), zoomed: _coverTarget != null);
    return GridView.builder(
      key: const Key('grid'),
      controller: _scroll,
      physics: physics,
      padding: const EdgeInsets.all(_coverPad),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _cols,
        mainAxisExtent: extent,
        mainAxisSpacing: _coverGap,
        crossAxisSpacing: _coverGap,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) => _cover(_items[i], wide: wide, shuffle: shuffle, sizes: sizes),
    );
  }

  /// One cover of the grid: [item]'s, or with [shuffle] a random page from
  /// it, decoded [sizes] pixels wide.
  Widget _cover(
    LibraryItem item, {
    required bool wide,
    required bool shuffle,
    required ({int cover, int shuffled}) sizes,
  }) {
    // The fingers of a pinch open nothing as they rest or lift.
    bool pinched() => _zoomArea.currentState?.pinched ?? false;
    // A folder or series shuffles too: a random page of a random comic in it.
    final from = !shuffle
        ? null
        : switch (item) {
            BookItem(:final book) => book,
            FolderItem(:final folder) => shuffleBook(item.id, folder.books, _seed),
            SeriesItem(:final series) => shuffleBook(item.id, series.books, _seed),
            _ => null,
          };
    return CoverCard(
      item: item,
      marked: item is BookItem && _marked.contains(item.book.key),
      shufflePage: from == null ? null : shufflePage(from.key, from.pageCount, _seed),
      shuffleBook: item is BookItem ? null : from,
      selected: item.id == _selected,
      coverWidth: sizes.cover,
      shuffleSize: sizes.shuffled,
      onTap: () {
        if (!pinched()) _tap(item, wide: wide);
      },
      onLongPress: () {
        if (pinched()) return;
        setState(() {
          _selected = item.id;
          _detail = item is BookItem || item is FolderItem;
        });
      },
    );
  }
}
