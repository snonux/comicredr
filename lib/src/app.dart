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

import 'android_storage.dart';
import 'data/s3_sync.dart';
import 'data/settings_file.dart';
import 'data/settings_store.dart';
import 'help_zoom.dart';
import 'hotkeys.dart';
import 'input/keys_file.dart';
import 'input/reader_keyboard.dart';
import 'input/reader_touch.dart';
import 'input/touch_providers.dart';
import 'input/touch_zones.dart';
import 'keymap_overlay.dart';
import 'library/collection_dialog.dart';
import 'library/default_folder.dart';
import 'library/delete_book.dart';
import 'library/library_screen.dart';
import 'library/providers.dart';
import 'library/s3_actions.dart';
import 'library/scanner.dart';
import 'library/settings_transfer.dart';
import 'providers.dart';
import 'reader/bookmark_list.dart';
import 'reader/clock_flash.dart';
import 'reader/comic_details.dart';
import 'reader/open_book.dart';
import 'reader/page_grid.dart';
import 'reader/page_scrubber.dart';
import 'reader/parts_picker.dart';
import 'reader/reader_notifier.dart';
import 'reader/reader_view.dart';
import 'reader/recent_books.dart';
import 'reader/region.dart';
import 'reader/reset_dialog.dart';
import 'reader/scroll_speed.dart';
import 'reader/status_line.dart';
import 'undo_notice.dart';

class ComicRedrApp extends StatelessWidget {
  const ComicRedrApp({super.key, this.initialPath, this.addRoots = const [], this.navigatorObservers = const []});

  /// Told of every route pushed and popped (the dialogs): for tests that
  /// count them.
  final List<NavigatorObserver> navigatorObservers;

  /// A book to open at start, from the command line.
  final String? initialPath;

  /// Folders to add to the library at start (`--add-root`).
  final List<String> addRoots;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ComicRedr',
      debugShowCheckedModeBanner: false,
      // A ring around what has the keyboard focus, to follow Tab by.
      theme: withFocusRing(ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), useMaterial3: true)),
      darkTheme: withFocusRing(
        ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), brightness: Brightness.dark, useMaterial3: true),
      ),
      themeMode: ThemeMode.dark,
      // Above the Navigator, so dialogs too name the keys of the live keymap.
      builder: (context, child) => Consumer(
        builder: (context, ref, _) => KeyHints(keymap: ref.watch(keymapProvider), child: child!),
      ),
      navigatorObservers: navigatorObservers,
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
  StreamSubscription<S3Notice>? _s3Notices;
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

  /// The page parts picker (a two-finger tap, `gp`), and the split it
  /// last showed, to show first next time.
  bool _showParts = false;
  PageSplit _partsSplit = PageSplit.halves;
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
      // Storage access may have been granted meanwhile, which lets the
      // default Comics folder in.
      onResume: () {
        ref.read(readerProvider.notifier).resumeSitting();
        unawaited(ref.read(s3SyncProvider).sync());
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
      showNotice(
        ScaffoldMessenger.of(context),
        warnings.length == 1
            ? '${warnings.first}. ? shows the keys in use.'
            : '${warnings.length} problems in keys.toml; ? lists them with the keys in use.',
        duration: const Duration(seconds: 8),
        // The sync's first notice ("S3 is out of reach") comes within these 8 s.
        mustRead: true,
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
    } else if (widget.addRoots.isEmpty) {
      await _continueAtStart();
    }
    if (!mounted) return;
    await _rescan();
    if (!mounted) return;
    _s3Notices = ref.read(s3SyncProvider).notices.listen((n) {
      if (mounted) showNotice(ScaffoldMessenger.of(context), n.text, mustRead: n.failure);
    });
    unawaited(ref.read(s3SyncProvider).start());
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
    unawaited(_s3Notices?.cancel());
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

  /// Android: storage access first, explained in a sentence, then the
  /// folder as a real path.
  Future<String?> _askAndroidFolder() async {
    if (!await _hasAndroidAccess()) return null;
    return _askPath('Add a folder to the library', 'Add');
  }

  Future<bool> _hasAndroidAccess() async {
    try {
      return await hasAndroidStorageAccess(context, _storage);
    } on PlatformException catch (e) {
      if (mounted) ref.read(readerProvider.notifier).notice('Could not request storage access: ${e.message}');
      return false;
    }
  }

  /// A folder typed as a path: Android has no folder picker that gives one.
  Future<String?> _askPath(String title, String action) async {
    final field = TextEditingController(text: '/storage/emulated/0/Comics');
    final dir = await showDialog<String>(
      context: context,
      builder: (context) => DialogHotkeys(
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Folder'),
            // Enter in the field is the dialog's button.
            onSubmitted: (text) => Navigator.pop(context, text.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Mnemonic('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: Mnemonic(action)),
          ],
        ),
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
      showNotice(messenger, 'Wrote $n sidecar${n == 1 ? '' : 's'} to $dir');
    } catch (e) {
      showNotice(messenger, 'Could not export sidecars: $e', mustRead: true);
    }
  });

  static const _settingsFiles = XTypeGroup(label: 'ComicRedr settings', extensions: ['json']);

  /// Settings → Export settings: everything that is not a comic, as one
  /// file (SettingsFile). On the laptop the system's save dialog; on the
  /// phone a folder from Android's picker, with a new file in it.
  Future<void> _exportSettings() => _whilePicking(() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = settingsFileName(DateTime.now());
      final String path;
      if (Platform.isAndroid) {
        final dir = await _pickOnAndroid('pickFolder');
        if (dir == null) return;
        path = await writeNewFile(dir, name, await _settingsText());
      } else {
        final at = await getSaveLocation(
          suggestedName: name,
          confirmButtonText: 'Export',
          acceptedTypeGroups: const [_settingsFiles],
        );
        if (at == null) return;
        path = at.path;
        await File(path).writeAsString(await _settingsText(), flush: true);
      }
      showNotice(messenger, 'Settings exported to $path');
    } catch (e) {
      showNotice(messenger, 'Could not export settings: $e', mustRead: true);
    } finally {
      _keys.requestFocus();
    }
  });

  Future<String> _settingsText() async {
    await ref.read(readerProvider.notifier).flush();
    return exportSettings(ref.read(databaseProvider), keysPath: await keysFilePath());
  }

  /// Settings → Import settings: a file Export settings wrote, checked,
  /// shown and confirmed, then taken up at once.
  Future<void> _importSettings() => _whilePicking(() async {
    final messenger = ScaffoldMessenger.of(context);
    // To be read, all of it: a refusal, or what was imported and what was left out.
    void say(String text) => showNotice(messenger, text, duration: const Duration(seconds: 8), mustRead: true);
    try {
      final String? path;
      if (Platform.isAndroid) {
        path = await _pickOnAndroid('pickFile');
      } else {
        path = (await openFile(acceptedTypeGroups: const [_settingsFiles], confirmButtonText: 'Import'))?.path;
      }
      if (path == null) return;
      final SettingsFile file;
      try {
        file = SettingsFile.decode(await File(path).readAsString());
      } on SettingsFileException catch (e) {
        say('Could not import ${p.basename(path)}: ${e.message}');
        return;
      } on FileSystemException catch (e) {
        say('Could not read $path: ${e.message}');
        return;
      }
      if (!mounted || !await _confirmImport(p.basename(path), file)) return;
      await ref.read(readerProvider.notifier).flush();
      final done = await importSettings(file, library: ref.read(libraryStoreProvider), keysPath: await keysFilePath());
      await _takeUpImport(done);
      say(importNotice(done));
    } catch (e) {
      say('Could not import settings: $e');
    } finally {
      _keys.requestFocus();
    }
  });

  /// Shows what [file] holds and asks before importing it.
  Future<bool> _confirmImport(String name, SettingsFile file) async {
    String n(int count, String one) => '$count $one${count == 1 ? '' : 's'}';
    final from = [
      if (file.appVersion case final v?) 'ComicRedr $v',
      if (file.exportedAt case final t?)
        'on ${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}',
    ];
    final holds = [
      n(file.settings.length, 'setting'),
      n(file.folders.length, 'library folder'),
      if (file.keysToml != null) 'keys.toml',
      n(file.positions.length, 'position'),
      n(file.bookmarks.where((b) => b.deletedAt == null).length, 'bookmark'),
      n(
        file.collections.where((c) => c.removedAt == null).length,
        'collection entry',
      ).replaceFirst('entrys', 'entries'),
      n(file.metaEditCount, 'edit'),
      n(file.completedMarkCount, 'completed mark'),
      n(file.history.length, 'history entry').replaceFirst('entrys', 'entries'),
    ];
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => DialogHotkeys(
        child: AlertDialog(
          title: Text('Import settings from $name?'),
          content: SizedBox(
            width: 520,
            child: Text(
              '${from.isEmpty ? '' : 'Exported from ${from.join(' ')}. '}It holds ${holds.join(', ')}.\n\n'
              'Your settings become the file\'s, except that where this device keeps its sidecars only changes when '
              'the file says. Positions, bookmarks, collections, edits, completed marks and history are merged '
              'with what is here. Its library folders that are on this device are added; none is taken out.',
            ),
          ),
          actions: _importButtons(context),
        ),
      ),
    );
    return go == true;
  }

  /// Cancel (Alt+C) and Import (Alt+I, and Enter: nothing is lost by it
  /// that the file does not say).
  List<Widget> _importButtons(BuildContext context) => [
    TextButton(
      key: const Key('importSettings-cancel'),
      onPressed: () => Navigator.pop(context, false),
      child: const Mnemonic('Cancel'),
    ),
    FilledButton(
      key: const Key('importSettings-go'),
      autofocus: true,
      onPressed: () => Navigator.pop(context, true),
      child: const Mnemonic('Import'),
    ),
  ];

  /// Makes everything an import changed show at once: the reader's and
  /// the library's settings, the touch preset, the keymap, the sidecars of
  /// the comics it named, and the library's folders.
  /// `g+` `g-`: smooth scrolling a notch faster or slower, said in the
  /// reader's status line or, in the library, a short notice.
  Future<void> _changeScrollSpeed(int by) async {
    final speed = ref.read(scrollSpeedProvider).notch(by);
    await ref.read(scrollSpeedProvider.notifier).pick(speed);
    _say('Smooth scrolling: ${speed.label.toLowerCase()} (${speed.index + 1} of ${ScrollSpeed.values.length})');
  }

  /// `g>` `g<`: the key glide a notch smoother or crisper.
  Future<void> _changeScrollSmoothness(int by) async {
    final smoothness = ref.read(scrollSmoothnessProvider).notch(by);
    await ref.read(scrollSmoothnessProvider.notifier).pick(smoothness);
    _say(
      'Scrolling smoothness: ${smoothness.label.toLowerCase()} '
      '(${smoothness.index + 1} of ${ScrollSmoothness.values.length})',
    );
  }

  /// Says [text] in the reader's status line or, in the library, a short
  /// notice ([mustRead] as for [showNotice]: something that did not work).
  void _say(String text, {bool mustRead = false}) {
    if (!mounted) return;
    if (ref.read(readerProvider).book != null) {
      ref.read(readerProvider.notifier).notice(text);
    } else {
      showNotice(ScaffoldMessenger.of(context), text, duration: const Duration(seconds: 2), mustRead: mustRead);
    }
  }

  Future<void> _takeUpImport(SettingsImport done) async {
    if (done.keysWritten) ref.read(reloadedKeymapProvider.notifier).set(await loadKeymap());
    await ref.read(readerProvider.notifier).reloadSettings();
    await ref.read(touchPresetProvider.notifier).reload();
    await ref.read(scrollSpeedProvider.notifier).reload();
    await ref.read(scrollSmoothnessProvider.notifier).reload();
    await _library.currentState?.reloadSettings();
    forgetGridZoom(ref);
    await ref.read(helpZoomProvider.notifier).reload();
    final sync = ref.read(sidecarSyncProvider)..placeChanged();
    done.books.forEach(sync.touch);
    unawaited(_rescan());
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

  /// `*`, `gC` and `gc` with a comic open; true when [c] was one of them. They
  /// are about the open comic, not the page under the cursor, so they also
  /// work over the page grid and the bookmark list, which would otherwise
  /// swallow them; both stay up. With no comic open they are left to the
  /// library, for the selected or marked covers.
  bool _onOpenComic(ReaderCommand c) {
    final book = ref.read(readerProvider).book;
    if (book == null) return false;
    switch (c.intent) {
      case ReaderIntent.toggleFavourite || ReaderIntent.toggleCompleted:
        unawaited(ref.read(readerProvider.notifier).handle(c));
      case ReaderIntent.addToCollection:
        unawaited(_collect(book));
      default:
        return false;
    }
    return true;
  }

  /// `gc` in the reader, the page grid or the bookmark list: asks for a
  /// collection for the open comic the way the library does ([askCollection]),
  /// then puts it there. The dialog goes up in this very call, before
  /// anything is awaited, so no key typed after `gc` is taken for a
  /// command: its field gets what is typed until it has the focus
  /// ([_typeAhead]). Nothing hands the focus back afterwards: `gc` only
  /// ever comes from [_keys], and the dialog's route gives the focus back
  /// to where it was when it goes, however it was left (the tests leave it
  /// by key, button, chip and a click beside it).
  Future<void> _collect(OpenBook book) async {
    final reader = ref.read(readerProvider.notifier);
    // Named as its cover is in the library, when it is there.
    final inLibrary = ref.read(booksProvider).value?.where((b) => b.key == book.key).firstOrNull;
    final what = inLibrary?.name ?? book.title;
    final name = await askCollection(context, ref, what: what, keys: [book.key]);
    if (!mounted || name == null) return;
    // Closed or swapped for another comic while the dialog was up: the
    // name was for that one, so nothing is written, and that is said
    // rather than left to look as if it had worked.
    if (!identical(ref.read(readerProvider).book, book)) {
      _say('$what is no longer open: not added to $name', mustRead: true);
      return;
    }
    await reader.addToCollection(name);
  }

  /// A key pressed while a collection question (`gc`, or a Collection
  /// button, in the reader or the library) is up but its field has not got
  /// the focus yet: typed into the question, never a command. Touches need
  /// nothing of the kind: the Navigator absorbs pointers from the push
  /// until the dialog's barrier is built.
  bool _typeAhead(KeyEvent event) => ref.read(collectionAskerProvider).typed(event);

  /// `gu` or `gU` in the reader: the open comic onto S3 or off it.
  Future<void> _s3OpenBook(OpenBook open, {required bool upload}) async {
    final books = await ref.read(libraryStoreProvider).books();
    final book = books.where((b) => b.key == open.key).firstOrNull;
    if (!mounted) return;
    if (book == null) {
      showNotice(ScaffoldMessenger.of(context), 'Only comics in the library can go on S3: add its folder (A)');
      return;
    }
    await (upload ? uploadBooks(context, ref, [book]) : removeBooksFromS3(context, ref, [book]));
    _keys.requestFocus();
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
    final onS3 = await ref.read(s3SyncProvider).onShelf(book.key).catchError((_) => false);
    if (!mounted) return;
    final choice = await askDelete(context, facts.withS3(onS3));
    _keys.requestFocus();
    if (choice == DeleteChoice.cancel) return;
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
        keepCover: onS3 && choice == DeleteChoice.here,
      );
      if (choice == DeleteChoice.everywhere) await ref.read(s3SyncProvider).removeFromS3([book.key]);
      // A sidecar left behind is to be read: "Removed X from S3" follows within moments.
      showNotice(messenger, deletedNotice(book.title, stuck), mustRead: stuck.isNotEmpty);
    } on FileSystemException catch (e) {
      showNotice(messenger, 'Could not delete ${book.title}: ${e.message}', mustRead: true);
      await reader.open(book.path);
    }
  }

  /// Another device read further in the book just opened: ask, don't jump.
  Future<void> _offer(PositionOffer offer) async {
    final at = offer.at;
    final where = 'page ${at.page + 1}${at.panel != null && at.panel! > 0 ? ', panel ${at.panel! + 1}' : ''}';
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => DialogHotkeys(
        child: AlertDialog(
          title: Text('Read further on ${at.deviceName}'),
          content: Text('This comic was last read on ${at.deviceName}, up to $where. Go there?'),
          actions: [
            TextButton(
              key: const Key('offerStay'),
              onPressed: () => Navigator.pop(context, false),
              child: const Mnemonic('Stay here'),
            ),
            FilledButton(
              key: const Key('offerGo'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: Mnemonic('Go to $where'),
            ),
          ],
        ),
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
                ? 'That has no path ComicRedr can read; pick it from the device\'s own storage'
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

  /// `C` and the library's Continue button: the comic read last, at the
  /// spot it was left, which the reader restores as for any reopened book.
  /// From inside a comic, the one read before it, so `C` goes back and
  /// forth between two. A comic that is gone gets a notice and is dropped,
  /// so `C` again tries the one before it.
  ///
  /// [atStart] is the start's own call: with no comic read yet it says
  /// nothing, since nobody asked.
  Future<void> _continueReading({bool atStart = false}) async {
    final reader = ref.read(readerProvider.notifier);
    final recent = ref.read(recentBooksProvider.notifier);
    final here = ref.read(readerProvider).book;
    final pick = await recent.pick(except: here?.key);
    if (!mounted) return;
    if (pick == null) {
      if (atStart) return;
      reader.notice(here == null ? 'No comic read yet to continue' : 'No other comic read before this one');
      return;
    }
    final path = pick.path;
    if (path == null) {
      reader.notice('${pick.book.title} is gone from ${p.dirname(pick.book.path)}');
      await recent.forget(pick.book.key);
      return;
    }
    await reader.open(path);
  }

  /// At start, when the command line named no comic, folder or library
  /// folder (a comic named there wins, and a scripted start that adds a
  /// library folder stays in the library): the comic read last, at the
  /// spot it was left, as `C` opens it. Settings → Library turns it off
  /// (`library.continueAtStart`, on unless set to false). A comic that is
  /// gone gets `C`'s notice and the library shows.
  Future<void> _continueAtStart() async {
    try {
      final on = await ref.read(settingsStoreProvider).loadBool(SettingsStore.continueAtStart);
      if (on == false || !mounted || ref.read(readerProvider).book != null) return;
      await _continueReading(atStart: true);
    } catch (e) {
      debugPrint('Could not open the comic read last: $e');
    }
  }

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

  /// The zoom keys while the `?` help is up: its text a step bigger or
  /// smaller for each press (a count is that many steps, `3+`), or back to
  /// the usual size. They come as intents, so keys set in keys.toml work.
  /// False for any other command.
  bool _sizeHelp(ReaderCommand c) {
    final size = ref.read(helpZoomProvider.notifier);
    switch (c.intent) {
      case ReaderIntent.zoomIn:
        size.step(c.times);
      case ReaderIntent.zoomOut:
        size.step(-c.times);
      case ReaderIntent.zoomReset:
        size.set(HelpZoom.usual);
      default:
        return false;
    }
    return true;
  }

  /// A command while the `?` help is up (never the key that closes it,
  /// which [_onCommand] takes first): true when it was the help's or is
  /// kept from what is behind, false when the help is away or the command
  /// is one that goes through it (fullscreen).
  bool _helpTook(ReaderCommand c) {
    if (!_showKeymap) return false;
    if (c.intent == ReaderIntent.search) {
      _overlay.currentState?.startSearch();
      return true;
    }
    if (c.intent == ReaderIntent.back) {
      if (!(_overlay.currentState?.back() ?? false)) setState(() => _showKeymap = false);
      return true;
    }
    // + - = in the help size its text, not the page or the covers behind it.
    if (_sizeHelp(c)) return true;
    // Nothing else reaches the library or the reader hidden behind the help:
    // Enter would open a book under it, gd ask to delete one.
    return c.intent != ReaderIntent.fullscreen;
  }

  /// Two keys of buttons that are the same on every screen (task 263):
  /// true when [c] was one of them.
  ///
  /// `u` presses the Undo of the notice along the bottom, wherever that
  /// notice shows: over the library, an open comic, the page grid, the
  /// help (so [_onCommand] asks this before [_helpTook], which keeps
  /// every other key from what is behind the help). The notice of
  /// something done in the library is still up when a comic is opened
  /// straight after, and its button says `Undo (u)` there too. With no
  /// such notice (it goes by itself after ten seconds, or when another
  /// notice comes) `u` does nothing and says nothing.
  ///
  /// Settings are the library's, and open over a comic as well; not over
  /// the help, which keeps every key but its own from what is behind.
  bool _buttonKey(ReaderCommand c) {
    if (c.intent == ReaderIntent.undo) {
      ref.read(undoNoticeProvider).press();
      return true;
    }
    if (c.intent == ReaderIntent.showSettings && !_showKeymap) {
      _library.currentState?.handle(c);
      return true;
    }
    return false;
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
    if (_buttonKey(c) || _helpTook(c)) return;
    // Shift+arrows mark covers in the library; in a comic they move as the
    // arrows alone do.
    if (ref.read(readerProvider).book != null) {
      final plain = switch (c.intent) {
        ReaderIntent.markLeft => ReaderIntent.scrollLeft,
        ReaderIntent.markRight => ReaderIntent.scrollRight,
        ReaderIntent.markUp => ReaderIntent.panUp,
        ReaderIntent.markDown => ReaderIntent.panDown,
        ReaderIntent.markToFirst => ReaderIntent.firstPage,
        ReaderIntent.markToLast => ReaderIntent.lastPage,
        _ => null,
      };
      if (plain != null) c = c.as(plain);
    }
    if (c.intent == ReaderIntent.scrollFaster || c.intent == ReaderIntent.scrollSlower) {
      unawaited(_changeScrollSpeed(c.intent == ReaderIntent.scrollFaster ? c.times : -c.times));
      return;
    }
    if (c.intent == ReaderIntent.scrollSmoother || c.intent == ReaderIntent.scrollCrisper) {
      unawaited(_changeScrollSmoothness(c.intent == ReaderIntent.scrollSmoother ? c.times : -c.times));
      return;
    }
    // Left and Right pan a zoomed page; anywhere else, and at the page's
    // edge, they step as they always did.
    if (c.intent == ReaderIntent.scrollLeft || c.intent == ReaderIntent.scrollRight) {
      final reading = ref.read(readerProvider).book != null && !_showPages && !_showBookmarks;
      if (reading && (_view.currentState?.handle(c) ?? false)) return;
      c = c.as(c.intent == ReaderIntent.scrollRight ? ReaderIntent.nextStep : ReaderIntent.prevStep);
    }
    if (c.intent == ReaderIntent.pickPart) {
      if (ref.read(readerProvider).book != null) _setShowParts(!_showParts);
      return;
    }
    // Any other key or touch closes the picker and does what it always
    // does; Esc or the back gesture only closes it.
    if (_showParts) {
      _setShowParts(false);
      if (c.intent == ReaderIntent.back) return;
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
    if (c.intent == ReaderIntent.continueReading) {
      unawaited(_continueReading());
      return;
    }
    if (_onOpenComic(c)) return;
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
      unawaited(ref.read(s3SyncProvider).sync());
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
    if (c.intent == ReaderIntent.uploadToS3 || c.intent == ReaderIntent.removeFromS3) {
      if (ref.read(readerProvider).book case final book?) {
        unawaited(_s3OpenBook(book, upload: c.intent == ReaderIntent.uploadToS3));
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

  void _setShowParts(bool on) {
    setState(() {
      _showParts = on;
      if (on) {
        _showPages = _showBookmarks = false;
        _partsSplit = ref.read(readerProvider).parts ?? _partsSplit;
      }
    });
    _keys.requestFocus();
  }

  /// A part, Whole page or Stop picked on the parts picker: as its keys.
  void _pickedPart(ReaderIntent intent) {
    final split = regionFor(intent)?.split;
    if (split != null) _partsSplit = split;
    _onCommand(ReaderCommand(intent));
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
      if (!identical(was, book) && (_showPages || _showBookmarks || _showParts)) {
        setState(() => _showPages = _showBookmarks = _showParts = false);
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
    // Watched whether the help shows or not, so the saved size is read at
    // the start and the help opens at it the first time.
    final helpStep = ref.watch(helpZoomProvider);
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
        typeAhead: _typeAhead,
        child: Scaffold(
          // A page guided view shows whole turns the background wine red.
          backgroundColor: s.onWholePage ? heldColour : Colors.black,
          body: DropTarget(
            onDragDone: (d) {
              if (d.files.isNotEmpty) unawaited(_openPath(d.files.first.path));
            },
            child: Stack(
              children: [
                _libraryUnder(s),
                if (s.book != null) s.fullscreen ? _fullscreenReader(s) : _windowedReader(s),
                Positioned.fill(child: ClockFlash(key: _clock)),
                if (_showKeymap)
                  KeymapOverlay(
                    key: _overlay,
                    keymap: keymap,
                    keysFile: keysLoad.path,
                    dataDir: ref.watch(appDataDirProvider),
                    warnings: keysLoad.load.warnings,
                    step: helpStep,
                    onStep: ref.read(helpZoomProvider.notifier).set,
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
  /// The library, which stays built under the reader, so Esc comes back
  /// to the same tab, search and cover.
  Widget _libraryUnder(ReaderState s) => Offstage(
    offstage: s.book != null,
    child: TickerMode(
      enabled: s.book == null,
      child: LibraryScreen(
        key: _library,
        onAddRoot: _addRoot,
        onExportSidecars: _exportSidecars,
        onExportSettings: _exportSettings,
        onImportSettings: _importSettings,
        onOpenFile: _pickFile,
        onOpenFolder: _pickFolder,
        onContinue: _continueReading,
        // Also what puts a folder taken out with gA back (its Undo).
        onRescan: _rescan,
        keysFocus: _keys,
        pending: s.book == null ? _pending : '',
      ),
    ),
  );

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
    if (_showParts)
      Positioned.fill(
        child: PartsPicker(split: _partsSplit, onPick: _pickedPart, onClose: () => _setShowParts(false)),
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
    partsOpen: _showParts,
    bookmarksOpen: _showBookmarks,
    s3Progress: s.book == null ? null : ref.watch(s3StatusProvider).value?.transfers[s.book!.key],
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
    final chrome = _chromeShown || _pending.isNotEmpty || _showPages || _showBookmarks || _showParts;
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
