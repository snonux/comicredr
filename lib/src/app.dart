import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import 'input/reader_keyboard.dart';
import 'input/reader_touch.dart';
import 'input/touch_providers.dart';
import 'input/touch_zones.dart';
import 'library/library_screen.dart';
import 'library/providers.dart';
import 'library/scanner.dart';
import 'providers.dart';
import 'reader/comic_details.dart';
import 'reader/guided.dart';
import 'reader/layout.dart';
import 'reader/bookmark_list.dart';
import 'reader/open_book.dart';
import 'reader/page_grid.dart';
import 'reader/page_scrubber.dart';
import 'reader/reader_notifier.dart';
import 'reader/reader_view.dart';
import 'reader/reset_dialog.dart';
import 'version.dart';

class ComicRedrApp extends StatelessWidget {
  const ComicRedrApp({super.key, this.initialPath, this.addRoots = const []});

  /// A book to open at start, from the command line.
  final String? initialPath;

  /// Folders to add to the library at start (`--add-root`).
  final List<String> addRoots;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ComicRedr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), brightness: Brightness.dark, useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: HomeScreen(initialPath: initialPath, addRoots: addRoots),
    );
  }
}

/// The library, and the reader over it once a book is open. Esc out of the
/// reader comes back to the library where you left it.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.initialPath, this.addRoots = const []});

  final String? initialPath;
  final List<String> addRoots;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _storage = MethodChannel('org.snonux.comicredr/storage');

  /// Linux: the GTK window's fullscreen, both ways (linux/runner).
  static const _window = MethodChannel('org.snonux.comicredr/window');

  /// How far up from the bottom the mouse brings the status line back in
  /// fullscreen, and how long the pointer and the status line stay after
  /// the mouse stops or a notice comes.
  static const _edge = 96.0;
  static const _linger = Duration(milliseconds: 1500);
  static const _noticeLinger = Duration(milliseconds: 2500);

  final _view = GlobalKey<ReaderViewState>();
  final _library = GlobalKey<LibraryScreenState>();
  final _overlay = GlobalKey<KeymapOverlayState>();
  final _grid = GlobalKey<PageGridState>();
  final _bookmarkList = GlobalKey<BookmarkListState>();
  final _keys = FocusNode(debugLabel: 'keys');
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _watch;
  String _pending = '';
  bool _showKeymap = false;

  /// The page grid (`p`) is open over the reader.
  bool _showPages = false;

  /// The bookmark list (`M`) is open over the reader.
  bool _showBookmarks = false;
  bool _picking = false;

  /// The details view (`I`) is open.
  bool _showDetails = false;

  /// In fullscreen: the mouse moved lately, so the pointer shows; the
  /// status line and progress bar show for a moment, or while the mouse is
  /// along the bottom edge.
  bool _pointerShown = false;
  bool _chromeShown = false;
  bool _mouseAtEdge = false;
  Timer? _pointerTimer;
  Timer? _chromeTimer;

  /// The touch zones drawn over the reader for a moment.
  bool _showZones = false;
  Timer? _zonesTimer;

  @override
  void initState() {
    super.initState();
    // Flush the reading position when the app is backgrounded or closed.
    _lifecycle = AppLifecycleListener(
      onPause: () => ref.read(readerProvider.notifier).flush(),
      // Android has no change notifications for the library folders, so it
      // rescans when the app comes back (design plan section 4).
      onResume: () {
        if (Platform.isAndroid) unawaited(ref.read(scannerProvider).scan());
      },
      onExitRequested: () async {
        await ref.read(readerProvider.notifier).flush();
        return ui.AppExitResponse.exit;
      },
    );
    _window.setMethodCallHandler((call) async {
      if (call.method == 'fullscreenChanged' && call.arguments is bool) {
        ref.read(readerProvider.notifier).setFullscreen(call.arguments as bool);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  /// The window follows the reader's fullscreen: on Linux no title bar or
  /// border, on Android no system bars.
  void _applyFullscreen(bool full) {
    if (Platform.isLinux) {
      unawaited(
        _window.invokeMethod<void>('setFullscreen', full).catchError((Object e) {
          debugPrint('Could not change fullscreen: $e');
        }),
      );
    } else {
      unawaited(SystemChrome.setEnabledSystemUIMode(full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
    }
    _pointerTimer?.cancel();
    _chromeTimer?.cancel();
    setState(() {
      _pointerShown = false;
      _chromeShown = false;
      _mouseAtEdge = false;
    });
  }

  /// A mouse moved over the reader in fullscreen: the pointer shows until
  /// it rests, and along the bottom edge the status line comes back.
  void _mouseMoved(PointerEvent e, double height) {
    if (e.kind != ui.PointerDeviceKind.mouse || !ref.read(readerProvider).fullscreen) return;
    final atEdge = e.localPosition.dy >= height - _edge;
    _pointerTimer?.cancel();
    _pointerTimer = Timer(_linger, () {
      if (mounted && !_mouseAtEdge) setState(() => _pointerShown = false);
    });
    if (atEdge) {
      _chromeTimer?.cancel();
    } else if (_mouseAtEdge) {
      _showChrome(_linger);
    }
    if (!_pointerShown || atEdge != _mouseAtEdge || (atEdge && !_chromeShown)) {
      setState(() {
        _pointerShown = true;
        _mouseAtEdge = atEdge;
        if (atEdge) _chromeShown = true;
      });
    }
  }

  void _mouseLeft() {
    if (!_mouseAtEdge) return;
    setState(() => _mouseAtEdge = false);
    _showChrome(_linger);
  }

  /// Shows the status line in fullscreen for [time].
  void _showChrome(Duration time) {
    _chromeTimer?.cancel();
    if (!_chromeShown) setState(() => _chromeShown = true);
    _chromeTimer = Timer(time, () {
      if (mounted && !_mouseAtEdge) setState(() => _chromeShown = false);
    });
  }

  Future<void> _start() async {
    final warnings = ref.read(keymapLoadProvider).load.warnings;
    if (warnings.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            warnings.length == 1
                ? '${warnings.first}. ? shows the keys in use.'
                : '${warnings.length} problems in keys.toml; ? lists them with the keys in use.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    }
    final store = ref.read(libraryStoreProvider);
    try {
      for (final root in widget.addRoots) {
        await store.addRoot(root);
      }
    } catch (e) {
      debugPrint('Could not add a library folder: $e');
    }
    final path = widget.initialPath;
    // Before the scan, so a folder it adds to the library is scanned too.
    if (path != null) await _openPath(path, scan: false);
    // Listens for the scan's end, so it is there before the first scan.
    ref.read(libraryDetectionProvider);
    await _rescan();
  }

  /// Scans every library folder, then watches them for changes.
  Future<void> _rescan() async {
    final scanner = ref.read(scannerProvider);
    try {
      await _watch?.cancel();
      _watch = await scanner.watch();
      await scanner.scan();
    } catch (e) {
      debugPrint('Library scan failed: $e');
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _zonesTimer?.cancel();
    _keys.dispose();
    _pointerTimer?.cancel();
    _chromeTimer?.cancel();
    _window.setMethodCallHandler(null);
    unawaited(_watch?.cancel());
    super.dispose();
  }

  /// Opens [path] from the command line, Open With, a drop or `O`: a book
  /// in the reader, or a folder of comics on the library's Folders tab,
  /// walked to that folder. A folder outside the library is added to it
  /// first. A folder of page images is a book, as the library counts it.
  Future<void> _openPath(String path, {bool scan = true}) async {
    final dir = p.normalize(p.absolute(path));
    if (await FileSystemEntity.isDirectory(dir)) {
      final found = await Isolate.run(() => findBooks(dir));
      if (found.isNotEmpty && !(found.length == 1 && found.single.relPath.isEmpty)) {
        await _browse(dir, scan: scan);
        return;
      }
    }
    // Not awaited: the library scan need not wait for the book.
    unawaited(ref.read(readerProvider.notifier).open(path));
  }

  Future<void> _browse(String dir, {required bool scan}) async {
    final store = ref.read(libraryStoreProvider);
    // The innermost library folder holding it, if one does.
    String? root;
    for (final r in await store.roots()) {
      if ((r.path == dir || p.isWithin(r.path, dir)) && (root == null || r.path.length > root.length)) root = r.path;
    }
    if (root == null) {
      await store.addRoot(dir);
      root = dir;
      if (scan) unawaited(_rescan());
    }
    if (ref.read(readerProvider).book != null) await ref.read(readerProvider.notifier).close();
    _library.currentState?.showFolder(dir, root: root);
  }

  Future<void> _addRoot() async {
    if (_picking) return;
    _picking = true;
    try {
      final String? dir;
      if (Platform.isAndroid) {
        dir = await _askAndroidFolder();
      } else {
        dir = await getDirectoryPath(confirmButtonText: 'Add to library');
      }
      if (dir == null || dir.isEmpty) return;
      if (!await Directory(dir).exists()) {
        ref.read(readerProvider.notifier).notice('No such folder: $dir');
        return;
      }
      await ref.read(libraryStoreProvider).addRoot(dir);
      await _rescan();
    } finally {
      _picking = false;
    }
  }

  /// Android: All-files access first, explained in a sentence, then the
  /// folder as a real path.
  Future<String?> _askAndroidFolder() async {
    final granted = await _storage.invokeMethod<bool>('hasAllFilesAccess').catchError((_) => true) ?? true;
    if (!mounted) return null;
    if (!granted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow access to your comics'),
          content: const Text(
            'ComicRedr reads comics where they are on the phone. Android asks for that once, '
            'as "All files access", on a settings page. Turn it on there, come back, and add the folder again.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (go == true) await _storage.invokeMethod<void>('requestAllFilesAccess');
      return null;
    }
    return _askPath('Add a folder to the library', 'Add');
  }

  /// A folder typed as a path: Android has no folder picker that gives one.
  Future<String?> _askPath(String title, String action) async {
    final field = TextEditingController(text: '/storage/emulated/0/Comics');
    final dir = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: Text(action)),
        ],
      ),
    );
    field.dispose();
    return dir;
  }

  /// "Export sidecars": every book's sidecar, written under a folder of the
  /// person's choosing and laid out like the library, for books whose own
  /// folder cannot be written to (design plan section 7).
  Future<void> _exportSidecars() async {
    if (_picking) return;
    _picking = true;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = Platform.isAndroid
          ? await _askPath('Export sidecars to', 'Export')
          : await getDirectoryPath(confirmButtonText: 'Export sidecars here');
      if (dir == null || dir.isEmpty) return;
      final n = await ref.read(sidecarSyncProvider).exportAll(dir);
      messenger.showSnackBar(SnackBar(content: Text('Wrote $n sidecar${n == 1 ? '' : 's'} to $dir')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not export sidecars: $e')));
    } finally {
      _picking = false;
    }
  }

  /// `I` in the reader: the open comic's details. A page picked in them is
  /// gone to; Redo panels resets the comic's panels, as `X` does.
  Future<void> _details(OpenBook book) async {
    if (_showDetails) return;
    _showDetails = true;
    try {
      await showComicDetails(
        context,
        book,
        currentPage: ref.read(readerProvider).page,
        closeKeys: _keysFor(ReaderIntent.showDetails),
        onJump: (page) => ref.read(readerProvider.notifier).jumpTo(page),
        onRedoPanels: () => ref.read(readerProvider.notifier).reset(ResetScope.panels),
      );
    } finally {
      _showDetails = false;
      _keys.requestFocus();
    }
  }

  /// The single characters bound to [intent], for a dialog that closes on
  /// the key that opened it.
  Set<String> _keysFor(ReaderIntent intent) => {
    for (final b in ref.read(keymapProvider).bindings)
      if (b.intent == intent && b.keys.length == 1 && b.keys.single.length == 1) b.keys.single,
  };

  /// `X` in the reader: asks, then resets the open comic.
  Future<void> _reset(String title) async {
    final scope = await askReset(context, title);
    _keys.requestFocus();
    if (scope != null) await ref.read(readerProvider.notifier).reset(scope);
  }

  /// Another device read further in the book just opened: ask, don't jump.
  Future<void> _offer(PositionOffer offer) async {
    final at = offer.at;
    final where = 'page ${at.page + 1}${at.panel != null && at.panel! > 0 ? ', panel ${at.panel! + 1}' : ''}';
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Read further on ${at.deviceName}'),
        content: Text('This comic was last read on ${at.deviceName}, up to $where. Go there?'),
        actions: [
          TextButton(
            key: const Key('offerStay'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay here'),
          ),
          FilledButton(
            key: const Key('offerGo'),
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text('Go to $where'),
          ),
        ],
      ),
    );
    _keys.requestFocus();
    final reader = ref.read(readerProvider.notifier);
    if (go == true && ref.read(readerProvider).book?.key == offer.contentKey) {
      await reader.acceptOffer(offer);
    } else {
      ref.read(positionOfferProvider.notifier).set(null);
    }
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    _picking = true;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Comics',
            extensions: ['cbz', 'cbr', 'cbt', 'zip', 'epub', 'pdf', 'png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      if (file != null) await ref.read(readerProvider.notifier).open(file.path);
    } finally {
      _picking = false;
    }
  }

  Future<void> _pickFolder() async {
    if (_picking) return;
    _picking = true;
    try {
      final dir = await getDirectoryPath(confirmButtonText: 'Open as a book');
      if (dir != null) await _openPath(dir);
    } finally {
      _picking = false;
    }
  }

  /// Android's back button or gesture: the same as Esc, one level at a
  /// time, and it leaves the app only from the library's top level. Without
  /// this, back in the reader closed the whole app.
  void _systemBack() {
    if (_showKeymap || ref.read(readerProvider).book != null) {
      _onCommand(const ReaderCommand(ReaderIntent.back));
    } else if (!(_library.currentState?.back() ?? false)) {
      unawaited(SystemNavigator.pop());
    }
  }

  /// Shows the touch zones over the reader for a few seconds.
  void _flashZones() {
    _zonesTimer?.cancel();
    setState(() => _showZones = true);
    _zonesTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showZones = false);
    });
  }

  void _onCommand(ReaderCommand c) {
    if (c.intent == ReaderIntent.showTouchZones) {
      if (ref.read(readerProvider).book == null) {
        _library.currentState?.handle(c);
      } else {
        _flashZones();
      }
      return;
    }
    if (c.intent == ReaderIntent.showKeymap) {
      setState(() => _showKeymap = !_showKeymap);
      return;
    }
    if (_showKeymap && c.intent == ReaderIntent.search) {
      _overlay.currentState?.startSearch();
      return;
    }
    if (_showKeymap && c.intent == ReaderIntent.back) {
      if (!(_overlay.currentState?.back() ?? false)) setState(() => _showKeymap = false);
      return;
    }
    if (c.intent == ReaderIntent.pageGrid && ref.read(readerProvider).book != null) {
      _setShowPages(!_showPages);
      return;
    }
    if (c.intent == ReaderIntent.bookmarkList && ref.read(readerProvider).book != null && !_showPages) {
      _setShowBookmarks(!_showBookmarks);
      return;
    }
    if (c.intent == ReaderIntent.showDetails) {
      if (ref.read(readerProvider).book case final book?) {
        // Over the page grid or the bookmark list, it takes their place.
        if (_showPages) _setShowPages(false);
        if (_showBookmarks) _setShowBookmarks(false);
        unawaited(_details(book));
      } else {
        _library.currentState?.handle(c);
      }
      return;
    }
    if (_showPages) {
      _grid.currentState?.handle(c);
      return;
    }
    if (_showBookmarks) {
      _bookmarkList.currentState?.handle(c);
      return;
    }
    if (c.intent == ReaderIntent.openFile) {
      unawaited(_pickFile());
      return;
    }
    if (c.intent == ReaderIntent.openFolder) {
      unawaited(_pickFolder());
      return;
    }
    if (c.intent == ReaderIntent.addRoot) {
      unawaited(_addRoot());
      return;
    }
    if (c.intent == ReaderIntent.rescan) {
      unawaited(_rescan());
      return;
    }
    if (c.intent == ReaderIntent.resetBook) {
      if (ref.read(readerProvider).book case final book?) {
        unawaited(_reset(book.title));
      } else {
        _library.currentState?.handle(c);
      }
      return;
    }
    if (ref.read(readerProvider).book == null) {
      _library.currentState?.handle(c);
      return;
    }
    if (_view.currentState?.handle(c) ?? false) return;
    unawaited(ref.read(readerProvider.notifier).handle(c));
  }

  void _setShowPages(bool on) {
    setState(() {
      _showPages = on;
      if (on) _showBookmarks = false;
    });
    _keys.requestFocus();
  }

  void _setShowBookmarks(bool on) {
    setState(() => _showBookmarks = on);
    _keys.requestFocus();
  }

  /// A page picked in the grid or on the progress bar.
  void _jumpTo(int page) {
    ref.read(readerProvider.notifier).jumpTo(page);
    if (_showPages) _setShowPages(false);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    ref.listen(readerProvider.select((s) => s.book), (was, book) {
      if (!identical(was, book) && (_showPages || _showBookmarks)) {
        setState(() => _showPages = _showBookmarks = false);
      }
    });
    ref.listen(readerProvider.select((s) => s.fullscreen), (_, full) => _applyFullscreen(full));
    // A notice in fullscreen shows on the status line for a moment.
    ref.listen(readerProvider.select((s) => s.message), (_, message) {
      if (message != null && ref.read(readerProvider).fullscreen) _showChrome(_noticeLinger);
    });
    ref.listen(positionOfferProvider, (_, offer) {
      if (offer != null) unawaited(_offer(offer));
    });
    // The first book opened after picking a touch preset shows its zones.
    ref.listen(readerProvider.select((s) => s.book != null && s.pageCount > 0), (_, open) {
      if (open && ref.read(touchPresetProvider.notifier).takeNewPick()) _flashZones();
    });
    final keymap = ref.watch(keymapProvider);
    final keysLoad = ref.watch(keymapLoadProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _systemBack();
      },
      child: ReaderKeyboard(
        keymap: keymap,
        onCommand: _onCommand,
        onPendingChanged: (p) => setState(() => _pending = p),
        focusNode: _keys,
        child: Scaffold(
          // A page guided view holds on turns the background wine red.
          backgroundColor:
              s.held && s.guided && (s.pauseCue == PauseCue.colour || MediaQuery.disableAnimationsOf(context))
              ? heldColour
              : Colors.black,
          body: DropTarget(
            onDragDone: (d) {
              if (d.files.isNotEmpty) unawaited(_openPath(d.files.first.path));
            },
            child: Stack(
              children: [
                // The library stays built under the reader, so Esc comes back
                // to the same tab, search and cover.
                Offstage(
                  offstage: s.book != null,
                  child: TickerMode(
                    enabled: s.book == null,
                    child: LibraryScreen(
                      key: _library,
                      onAddRoot: _addRoot,
                      onExportSidecars: _exportSidecars,
                      onOpenFile: _pickFile,
                      onOpenFolder: _pickFolder,
                      keysFocus: _keys,
                      pending: s.book == null ? _pending : '',
                    ),
                  ),
                ),
                if (s.book != null) s.fullscreen ? _fullscreenReader(s) : _windowedReader(s),
                if (_showKeymap)
                  KeymapOverlay(
                    key: _overlay,
                    keymap: keymap,
                    keysFile: keysLoad.path,
                    warnings: keysLoad.load.warnings,
                    onDone: _keys.requestFocus,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension on _HomeScreenState {
  Widget get _page => ReaderTouch(
    onCommand: _onCommand,
    viewTransform: () => _view.currentState?.transform,
    guided: () => ref.read(readerProvider).guided,
    touchMap: () => ref.read(touchMapProvider),
    child: ReaderView(key: _view),
  );

  /// What lies over the page: the progress bar, and whatever is open.
  /// [chrome] false (fullscreen at rest) leaves out the bar and the ribbon.
  List<Widget> _overPage(ReaderState s, {bool chrome = true}) => [
    if (chrome && s.bookmarksHere.isNotEmpty && !_showPages && !_showBookmarks)
      Positioned(
        top: 0,
        right: 20,
        child: Semantics(
          button: true,
          label: 'Bookmarked. Opens the bookmark list',
          child: GestureDetector(
            key: const Key('bookmarkRibbon'),
            onTap: () => _setShowBookmarks(true),
            child: Icon(
              Icons.bookmark,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
              shadows: const [Shadow(blurRadius: 4)],
            ),
          ),
        ),
      ),
    Positioned.fill(
      child: PageScrubber(onPick: _jumpTo, hidden: !chrome),
    ),
    if (_showBookmarks)
      Positioned.fill(
        child: BookmarkList(
          key: _bookmarkList,
          onClose: () => _setShowBookmarks(false),
          onDialogDone: _keys.requestFocus,
        ),
      ),
    if (_showPages)
      Positioned.fill(
        child: PageGrid(
          key: _grid,
          onPick: _jumpTo,
          onClose: () => _setShowPages(false),
          onDetails: () => _onCommand(const ReaderCommand(ReaderIntent.showDetails)),
        ),
      ),
    if (_showZones)
      Positioned.fill(
        child: IgnorePointer(
          child: TouchZonesView(
            key: const Key('touch-zones'),
            map: ref.watch(touchMapProvider),
            rightToLeft: s.rightToLeft,
          ),
        ),
      ),
  ];

  Widget _statusLine(ReaderState s) => _StatusLine(
    state: s,
    pending: _pending,
    gridOpen: _showPages,
    bookmarksOpen: _showBookmarks,
    onCommand: _onCommand,
  );

  /// The page above the status line.
  Widget _windowedReader(ReaderState s) => Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: _page),
            ..._overPage(s),
          ],
        ),
      ),
      _statusLine(s),
    ],
  );

  /// Only the page, over the whole screen. The status line and progress
  /// bar come over it for a moment on a notice, while keys are typed, or
  /// while the mouse is along the bottom; the pointer hides when the mouse
  /// rests. The page keeps its size either way, so nothing reflows.
  Widget _fullscreenReader(ReaderState s) {
    final chrome = _chromeShown || _pending.isNotEmpty || _showPages || _showBookmarks;
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        cursor: _pointerShown ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: (e) => _mouseMoved(e, constraints.maxHeight),
        onExit: (_) => _mouseLeft(),
        child: Listener(
          onPointerMove: (e) => _mouseMoved(e, constraints.maxHeight),
          child: Stack(
            children: [
              Positioned.fill(child: _page),
              Positioned.fill(
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(children: _overPage(s, chrome: chrome)),
                    ),
                    if (chrome) _statusLine(s),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.state,
    required this.pending,
    required this.onCommand,
    this.gridOpen = false,
    this.bookmarksOpen = false,
  });

  /// Where guided view is on the page, or why it shows the whole page.
  static String _guided(ReaderState s) {
    final found = s.panels[s.page];
    if (found == null) return 'guided: finding panels…';
    final stops = s.stopsOn(s.page);
    if (stops.isEmpty) return 'guided: whole page (${found.gate.reasons.first})';
    if (s.panelIndex < 0) {
      return s.panel >= pageEnd
          ? 'guided: whole page, ${stops.length} panels read'
          : 'guided: whole page, then ${stops.length} panels';
    }
    final panel = 'guided: panel ${s.panelIndex + 1} / ${stops.length}';
    if (!s.balloons) return panel;
    final n = s.balloonsOn(s.page, s.panelIndex).length;
    if (found.balloons.isEmpty) return '$panel  ·  no balloons found';
    return n == 0
        ? '$panel  ·  no balloons'
        : '$panel  ·  balloon ${s.balloonIndex < 0 ? '–' : s.balloonIndex + 1} / $n';
  }

  final ReaderState state;
  final String pending;

  /// Whether the page grid is open.
  final bool gridOpen;

  /// Whether the bookmark list is open.
  final bool bookmarksOpen;

  /// For the buttons: a phone without a keyboard has no other way into
  /// guided view, balloons or bookmarks.
  final ValueChanged<ReaderCommand> onCommand;

  Widget _button(String key, IconData icon, String tip, ReaderIntent intent, {bool on = false}) => IconButton(
    key: Key(key),
    icon: Icon(icon),
    tooltip: tip,
    isSelected: on,
    // Full 48 px targets: the Fedora laptop has a touchscreen too.
    onPressed: () => onCommand(ReaderCommand(intent)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = state.book;
    final unit = state.unit;
    final pages = unit.isEmpty
        ? ''
        : unit.length == 1
        ? 'page ${unit.first + 1} / ${state.pageCount}'
        : 'pages ${unit.first + 1}–${unit.last + 1} / ${state.pageCount}';
    final details = [
      if (book != null) pages,
      if (book != null && state.guided) _guided(state),
      if (book != null && !state.guided && state.mode == PageMode.spread) 'spread',
      if (state.rightToLeft) 'RTL',
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone in portrait has room for about 40 characters: the page and
        // panel counters come first there, the title after them, and the
        // file name, which repeats the title, is left out.
        final narrow = constraints.maxWidth < 600;
        final left = (narrow ? [...details, if (book != null) book.title] : [if (book != null) book.title, ...details])
            .join('  ·  ');
        return Container(
          color: theme.colorScheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                // A live region, so a screen reader reads out each notice
                // and page turn as it happens.
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    state.message ?? left,
                    key: const Key('status'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Text(
                pending,
                key: const Key('pending'),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (book != null && !narrow) ...[
                const SizedBox(width: 12),
                Text(p.basename(book.path), style: theme.textTheme.bodySmall),
              ],
              if (book != null) ...[
                const SizedBox(width: 4),
                if (state.guided)
                  _button(
                    'balloonsButton',
                    state.balloons ? Icons.chat_bubble : Icons.chat_bubble_outline,
                    'Balloon by balloon (b)',
                    ReaderIntent.toggleBalloons,
                    on: state.balloons,
                  ),
                _button(
                  'guidedButton',
                  state.guided ? Icons.view_quilt : Icons.view_quilt_outlined,
                  'Guided view (v)',
                  ReaderIntent.toggleGuided,
                  on: state.guided,
                ),
                _button('pagesButton', Icons.grid_view, 'Pages (p)', ReaderIntent.pageGrid, on: gridOpen),
                // A phone has no room for it here; the page grid has one.
                if (!narrow) _button('detailsButton', Icons.info_outline, 'Details (I)', ReaderIntent.showDetails),
                if (state.bookmarksHere.isNotEmpty)
                  _button(
                    'bookmarkButton',
                    Icons.bookmark,
                    'Remove the bookmark here (mm)',
                    ReaderIntent.bookmark,
                    on: true,
                  )
                else
                  _button('bookmarkButton', Icons.bookmark_add_outlined, 'Bookmark here (mm)', ReaderIntent.bookmark),
                _button(
                  'bookmarksButton',
                  Icons.bookmarks_outlined,
                  'Bookmarks (M)',
                  ReaderIntent.bookmarkList,
                  on: bookmarksOpen,
                ),
                _button(
                  'fullscreenButton',
                  state.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  state.fullscreen ? 'Leave fullscreen (f, Esc)' : 'Fullscreen (f)',
                  ReaderIntent.fullscreen,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The `?` overlay, generated from the same table the app binds from, so it
/// cannot drift from the real keys. `/` searches it: fuzzy words, or a
/// regular expression between slashes. Esc clears the search, then closes.
class KeymapOverlay extends StatefulWidget {
  const KeymapOverlay({super.key, required this.keymap, this.keysFile, this.warnings = const [], this.onDone});

  final Keymap keymap;

  /// The `keys.toml` the keymap was read from, if there was one.
  final String? keysFile;

  /// What was wrong in that file.
  final List<String> warnings;

  /// Called when the search field hands the keys back to the reader.
  final VoidCallback? onDone;

  @override
  State<KeymapOverlay> createState() => KeymapOverlayState();
}

class KeymapOverlayState extends State<KeymapOverlay> {
  final _query = TextEditingController();
  final _field = FocusNode(debugLabel: 'keymap-search');
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    _field.dispose();
    super.dispose();
  }

  /// `/` while the overlay is open.
  void startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _field.requestFocus();
    });
  }

  /// Esc: clears a search first. Returns false when there was none, and
  /// the overlay should close.
  bool back() {
    if (!_searching && _query.text.isEmpty) return false;
    _stopSearch(clear: true);
    return true;
  }

  void _stopSearch({required bool clear}) {
    setState(() {
      if (clear) {
        _query.clear();
        _searching = false;
      }
    });
    _field.unfocus();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = searchKeymap(widget.keymap, _query.text);
    final mono = const TextStyle(fontFamily: 'monospace');
    return Positioned.fill(
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        label: 'Keyboard shortcuts',
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _searching || _query.text.isNotEmpty
                    ? CallbackShortcuts(
                        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _stopSearch(clear: true)},
                        child: TextField(
                          key: const Key('keymap-search'),
                          controller: _query,
                          focusNode: _field,
                          autofocus: true,
                          style: mono,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search: words, fuzzy (fulscr), or /regex/',
                            errorText: found.error,
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                          // Enter keeps the filter and hands the keys back.
                          onSubmitted: (_) => _stopSearch(clear: false),
                        ),
                      )
                    : Text('Keys  ·  / searches  ·  Esc closes', style: theme.textTheme.titleMedium),
              ),
              if (widget.keysFile != null || widget.warnings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Text(
                    [if (widget.keysFile != null) 'Keys from ${widget.keysFile}', ...widget.warnings].join('\n'),
                    key: const Key('keymap-file'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: widget.warnings.isEmpty ? null : theme.colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    found.entries.isEmpty && found.error == null
                        ? Center(child: Text('Nothing matches "${_query.text}"'))
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
                            children: [
                              for (final e in found.entries)
                                MergeSemantics(
                                  child: Padding(
                                    key: ValueKey('keymap-${e.intent.name}'),
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 200,
                                          child: Text(e.keys.isEmpty ? '(no key)' : e.keys.join('  '), style: mono),
                                        ),
                                        Expanded(child: Text(e.intent.description)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    // In a corner, so the keymap list keeps its whole height.
                    Positioned(
                      right: 24,
                      bottom: 16,
                      child: Text(
                        'ComicRedr $appVersion',
                        key: const Key('keymap-version'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
