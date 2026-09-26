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
import 'keymap_overlay.dart';
import 'library/default_folder.dart';
import 'library/delete_book.dart';
import 'library/library_screen.dart';
import 'library/providers.dart';
import 'library/scanner.dart';
import 'providers.dart';
import 'reader/bookmark_list.dart';
import 'reader/clock_flash.dart';
import 'reader/comic_details.dart';
import 'reader/open_book.dart';
import 'reader/page_grid.dart';
import 'reader/page_scrubber.dart';
import 'reader/reader_notifier.dart';
import 'reader/reader_view.dart';
import 'reader/reset_dialog.dart';
import 'reader/status_line.dart';

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
  final _clock = GlobalKey<ClockFlashState>();
  Timer? _zonesTimer;

  @override
  void initState() {
    super.initState();
    // Flush the reading position when the app is backgrounded or closed.
    _lifecycle = AppLifecycleListener(
      onPause: () => ref.read(readerProvider.notifier).flush(),
      // Android has no change notifications for the library folders, so it
      // rescans when the app comes back (design plan section 4).
      // All files access may have been granted meanwhile, which lets the
      // default Comics folder in.
      onResume: () {
        ref.read(readerProvider.notifier).resumeSitting();
        if (Platform.isAndroid) unawaited(_addDefaultFolder().then((_) => ref.read(scannerProvider).scan()));
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
    unawaited(ref.read(readerProvider.notifier).loadFullscreen());
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
    await _addDefaultFolder();
    final path = widget.initialPath;
    // Before the scan, so a folder it adds to the library is scanned too.
    // A path that fails to open costs that book, not the library's scan.
    if (path != null) {
      try {
        await _openPath(path, scan: false);
      } catch (e) {
        debugPrint('Could not open $path: $e');
      }
    }
    if (!mounted) return;
    // Listens for the scan's end, so it is there before the first scan.
    ref.read(libraryDetectionProvider);
    await _rescan();
  }

  /// ~/Comics (on Android the Comics folder in shared storage, once the app
  /// may read it) while no library folder is set up.
  Future<void> _addDefaultFolder() async {
    try {
      if (Platform.isAndroid) {
        final granted = await _storage.invokeMethod<bool>('hasAllFilesAccess').catchError((_) => false) ?? false;
        if (!granted) return;
      }
      await addDefaultFolder(ref.read(libraryStoreProvider), ref.read(settingsStoreProvider), defaultComicsFolder());
    } catch (e) {
      debugPrint('Could not add the default comics folder: $e');
    }
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

  /// Runs [pick] unless a picker or dialog from another one is still open,
  /// so a second key press never stacks a second picker.
  Future<void> _whilePicking(Future<void> Function() pick) async {
    if (_picking) return;
    _picking = true;
    try {
      await pick();
    } finally {
      _picking = false;
    }
  }

  Future<void> _addRoot() => _whilePicking(() async {
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
  });

  /// Android: All-files access first, explained in a sentence, then the
  /// folder as a real path.
  Future<String?> _askAndroidFolder() async {
    if (!await _hasAndroidAccess()) return null;
    return _askPath('Add a folder to the library', 'Add');
  }

  /// Whether All-files access is on; when it is not, says why it is needed
  /// and offers the settings page.
  Future<bool> _hasAndroidAccess() async {
    final granted = await _storage.invokeMethod<bool>('hasAllFilesAccess').catchError((_) => true) ?? true;
    if (!mounted) return false;
    if (!granted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow access to your comics'),
          content: const Text(
            'ComicRedr reads comics where they are on the phone. Android asks for that once, '
            'as "All files access", on a settings page. Turn it on there, then come back and try again.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (go == true) await _storage.invokeMethod<void>('requestAllFilesAccess');
    }
    return granted;
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
  Future<void> _exportSidecars() => _whilePicking(() async {
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
    }
  });

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

  /// `gd` or Shift+Delete in the reader: asks, then deletes the open comic
  /// and goes back to the library with the cover next to it selected. When
  /// the delete fails the comic opens again where it was.
  Future<void> _delete(OpenBook book) async {
    final messenger = ScaffoldMessenger.of(context);
    final reader = ref.read(readerProvider.notifier);
    final facts = await deleteFacts(
      book.title,
      book.path,
      folder: book.folder,
      pages: ref.read(readerProvider).pageCount,
    );
    if (!mounted) return;
    final go = await askDelete(context, facts);
    _keys.requestFocus();
    if (!go) return;
    _library.currentState?.selectNeighbourOf(book.key);
    await reader.close();
    try {
      final stuck = await deleteComic(
        path: book.path,
        contentKey: book.key,
        folder: book.folder,
        sidecars: ref.read(sidecarSyncProvider),
        store: ref.read(libraryStoreProvider),
        coverDir: ref.read(coverDirProvider),
      );
      messenger.showSnackBar(SnackBar(content: Text(deletedNotice(book.title, stuck))));
    } on FileSystemException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete ${book.title}: ${e.message}')));
      await reader.open(book.path);
    }
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

  /// Android's own picker, answered with the real path of what was picked
  /// (`MainActivity.pathOf`). file_selector's picker hands back a copy in
  /// the app's cache instead, read whole into memory: the sidecar, the
  /// history and Delete then went to the copy, never to the comic.
  Future<String?> _pickOnAndroid(String method) async {
    if (!await _hasAndroidAccess()) return null;
    try {
      return await _storage.invokeMethod<String>(method);
    } on PlatformException catch (e) {
      ref
          .read(readerProvider.notifier)
          .notice(
            e.code == 'no-path'
                ? 'That has no path on the phone ComicRedr can read; pick it from the phone\'s own storage'
                : 'Could not open the picker: ${e.message}',
          );
      return null;
    }
  }

  Future<void> _pickFile() => _whilePicking(() async {
    if (Platform.isAndroid) {
      final path = await _pickOnAndroid('pickFile');
      if (path != null) await ref.read(readerProvider.notifier).open(path);
      return;
    }
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Comics',
          extensions: ['cbz', 'cbr', 'cbt', 'zip', 'epub', 'pdf', 'png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (file != null) await ref.read(readerProvider.notifier).open(file.path);
  });

  Future<void> _pickFolder() => _whilePicking(() async {
    final dir = Platform.isAndroid
        ? await _pickOnAndroid('pickFolder')
        : await getDirectoryPath(confirmButtonText: 'Open as a book');
    if (dir != null) await _openPath(dir);
  });

  /// Android's back button or gesture: the same as Esc, one level at a
  /// time, and it leaves the app only from the library's top level. Without
  /// this, back in the reader closed the whole app.
  void _systemBack() {
    if (_showKeymap || ref.read(readerProvider).book != null) {
      _onCommand(const ReaderCommand(ReaderIntent.back));
    } else if (!(_library.currentState?.back() ?? false)) {
      // As Esc: fullscreen goes first, then the app.
      if (ref.read(readerProvider).fullscreen) {
        ref.read(readerProvider.notifier).setFullscreen(false);
      } else {
        unawaited(SystemNavigator.pop());
      }
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
    // The time, anywhere: the library, the reader, fullscreen.
    if (c.intent == ReaderIntent.showTime) {
      _clock.currentState?.flash();
      return;
    }
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
    // Nothing else reaches the library or the reader hidden behind the help:
    // Enter would open a book under it, gd ask to delete one.
    if (_showKeymap && c.intent != ReaderIntent.fullscreen) return;
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
    if (c.intent == ReaderIntent.showFavourites) {
      // From the reader it leaves fullscreen and the book, as Esc would,
      // and goes there.
      unawaited(() async {
        final reader = ref.read(readerProvider.notifier);
        if (ref.read(readerProvider).fullscreen) reader.setFullscreen(false);
        await reader.close();
        _library.currentState?.handle(c);
      }());
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
    if (c.intent == ReaderIntent.deleteBook) {
      if (ref.read(readerProvider).book case final book?) {
        unawaited(_delete(book));
      } else {
        _library.currentState?.handle(c);
      }
      return;
    }
    if (ref.read(readerProvider).book == null) {
      final reader = ref.read(readerProvider.notifier);
      if (c.intent == ReaderIntent.fullscreen) {
        reader.setFullscreen(!ref.read(readerProvider).fullscreen);
        return;
      }
      final handled = _library.currentState?.handle(c) ?? false;
      // Esc with nothing left to back out of in the library leaves
      // fullscreen.
      if (c.intent == ReaderIntent.back && !handled) reader.setFullscreen(false);
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
                Positioned.fill(child: ClockFlash(key: _clock)),
                if (_showKeymap)
                  KeymapOverlay(
                    key: _overlay,
                    keymap: keymap,
                    keysFile: keysLoad.path,
                    dataDir: ref.watch(appDataDirProvider),
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

  Widget _statusLine(ReaderState s) => StatusLine(
    state: s,
    pending: _pending,
    gridOpen: _showPages,
    bookmarksOpen: _showBookmarks,
    onCommand: _onCommand,
  );

  /// The page above the status line, clear of the phone's status and
  /// navigation bars, which Android 15 and a return from fullscreen draw
  /// over the app.
  Widget _windowedReader(ReaderState s) => SafeArea(
    child: Column(
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
    ),
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
                    // Above the navigation bar while a swipe brings it back.
                    if (chrome) SafeArea(top: false, child: _statusLine(s)),
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
