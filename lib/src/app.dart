import 'dart:async';
import 'dart:io';
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
import 'library/library_screen.dart';
import 'library/providers.dart';
import 'providers.dart';
import 'reader/guided.dart';
import 'reader/layout.dart';
import 'reader/reader_notifier.dart';
import 'reader/reader_view.dart';
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

  final _view = GlobalKey<ReaderViewState>();
  final _library = GlobalKey<LibraryScreenState>();
  final _keys = FocusNode(debugLabel: 'keys');
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _watch;
  String _pending = '';
  bool _showKeymap = false;
  bool _picking = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final path = widget.initialPath;
    if (path != null) unawaited(ref.read(readerProvider.notifier).open(path));
    final store = ref.read(libraryStoreProvider);
    try {
      for (final root in widget.addRoots) {
        await store.addRoot(root);
      }
    } catch (e) {
      debugPrint('Could not add a library folder: $e');
    }
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
    _keys.dispose();
    unawaited(_watch?.cancel());
    super.dispose();
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
          XTypeGroup(label: 'Comics', extensions: ['cbz', 'cbr', 'zip', 'pdf']),
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
      if (dir != null) await ref.read(readerProvider.notifier).open(dir);
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

  void _onCommand(ReaderCommand c) {
    if (c.intent == ReaderIntent.showKeymap) {
      setState(() => _showKeymap = !_showKeymap);
      return;
    }
    if (_showKeymap && c.intent == ReaderIntent.back) {
      setState(() => _showKeymap = false);
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
    if (ref.read(readerProvider).book == null) {
      _library.currentState?.handle(c);
      return;
    }
    if (_view.currentState?.handle(c) ?? false) return;
    unawaited(ref.read(readerProvider.notifier).handle(c));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    ref.listen(readerProvider.select((s) => s.fullscreen), (_, full) {
      SystemChrome.setEnabledSystemUIMode(full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    });
    ref.listen(positionOfferProvider, (_, offer) {
      if (offer != null) unawaited(_offer(offer));
    });
    final keymap = ref.watch(keymapProvider);
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
          backgroundColor: Colors.black,
          body: DropTarget(
            onDragDone: (d) {
              if (d.files.isNotEmpty) ref.read(readerProvider.notifier).open(d.files.first.path);
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
                if (s.book != null)
                  Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ReaderTouch(
                                onCommand: _onCommand,
                                viewTransform: () => _view.currentState?.transform,
                                guided: () => ref.read(readerProvider).guided,
                                child: ReaderView(key: _view),
                              ),
                            ),
                            Positioned(left: 0, right: 0, bottom: 0, child: _ProgressBar(state: s)),
                          ],
                        ),
                      ),
                      if (!s.fullscreen || s.message != null || _pending.isNotEmpty)
                        _StatusLine(state: s, pending: _pending, onCommand: _onCommand),
                    ],
                  ),
                if (_showKeymap) KeymapOverlay(keymap: keymap),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How far through the book you are, as a thin bar along the bottom of the
/// page. It stays when fullscreen hides the status line. In guided view it
/// also moves panel by panel within the page.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.state});

  final ReaderState state;

  @override
  Widget build(BuildContext context) {
    final n = state.pageCount;
    final stops = state.guided ? state.stopsOn(state.page).length : 0;
    final within = stops == 0 || state.panel >= pageEnd ? 1.0 : (state.panelIndex + 1) / stops;
    final read = state.guided ? state.page + within : state.unit.last + 1.0;
    return LinearProgressIndicator(
      key: const Key('progress'),
      value: n == 0 ? 0 : (read / n).clamp(0.0, 1.0),
      minHeight: 3,
      backgroundColor: Colors.white12,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state, required this.pending, required this.onCommand});

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

  /// For the buttons: a phone without a keyboard has no other way into
  /// guided view, balloons or bookmarks.
  final ValueChanged<ReaderCommand> onCommand;

  Widget _button(String key, IconData icon, String tip, ReaderIntent intent, {bool on = false}) => IconButton(
    key: Key(key),
    icon: Icon(icon),
    tooltip: tip,
    isSelected: on,
    visualDensity: VisualDensity.compact,
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
                child: Text(
                  state.message ?? left,
                  key: const Key('status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                _button('bookmarkButton', Icons.bookmark_add_outlined, 'Bookmark here (mm)', ReaderIntent.bookmark),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The `?` overlay, generated from the same table the app binds from, so it
/// cannot drift from the real keys.
class KeymapOverlay extends StatelessWidget {
  const KeymapOverlay({super.key, required this.keymap});

  final Keymap keymap;

  @override
  Widget build(BuildContext context) {
    final byIntent = <ReaderIntent, List<Binding>>{};
    for (final b in keymap.bindings) {
      byIntent.putIfAbsent(b.intent, () => []).add(b);
    }
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: theme.colorScheme.surface.withValues(alpha: 0.96),
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(24),
              children: [
                for (final MapEntry(key: intent, value: bindings) in byIntent.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 200,
                          child: Text(
                            bindings.map(Keymap.describe).join('  '),
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        Expanded(child: Text(intent.description)),
                      ],
                    ),
                  ),
              ],
            ),
            // In a corner, so the keymap list keeps its whole height.
            Positioned(
              right: 24,
              bottom: 16,
              child: Text('ComicRedr $appVersion', key: const Key('keymap-version'), style: theme.textTheme.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}
