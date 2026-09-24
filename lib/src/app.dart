import 'dart:async';
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
import 'providers.dart';
import 'reader/layout.dart';
import 'reader/reader_notifier.dart';
import 'reader/reader_view.dart';

class ComicRedrApp extends StatelessWidget {
  const ComicRedrApp({super.key, this.initialPath});

  /// A book to open at start, from the command line.
  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ComicRedr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6FB4),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: ReaderScreen(initialPath: initialPath),
    );
  }
}

/// The one screen until the library arrives in M7: an empty state that
/// opens files, and the reader once a book is open.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, this.initialPath});

  final String? initialPath;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final _view = GlobalKey<ReaderViewState>();
  late final AppLifecycleListener _lifecycle;
  String _pending = '';
  bool _showKeymap = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // Flush the reading position when the app is backgrounded or closed.
    _lifecycle = AppLifecycleListener(
      onPause: () => ref.read(readerProvider.notifier).flush(),
      onExitRequested: () async {
        await ref.read(readerProvider.notifier).flush();
        return ui.AppExitResponse.exit;
      },
    );
    final path = widget.initialPath;
    if (path != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(readerProvider.notifier).open(path));
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
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
    if (_view.currentState?.handle(c) ?? false) return;
    unawaited(ref.read(readerProvider.notifier).handle(c));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    ref.listen(readerProvider.select((s) => s.fullscreen), (_, full) {
      SystemChrome.setEnabledSystemUIMode(full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    });
    final keymap = ref.watch(keymapProvider);
    return ReaderKeyboard(
      keymap: keymap,
      onCommand: _onCommand,
      onPendingChanged: (p) => setState(() => _pending = p),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: DropTarget(
          onDragDone: (d) {
            if (d.files.isNotEmpty) ref.read(readerProvider.notifier).open(d.files.first.path);
          },
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    if (s.book != null)
                      Positioned.fill(
                        child: ReaderTouch(
                          onCommand: _onCommand,
                          viewTransform: () => _view.currentState?.transform,
                          guided: () => ref.read(readerProvider).guided,
                          child: ReaderView(key: _view),
                        ),
                      )
                    else
                      _EmptyState(loading: s.loading, onOpen: _pickFile, onOpenFolder: _pickFolder),
                    if (s.book != null)
                      Positioned(left: 0, right: 0, bottom: 0, child: _ProgressBar(state: s)),
                    if (_showKeymap) KeymapOverlay(keymap: keymap),
                  ],
                ),
              ),
              if (!s.fullscreen || s.message != null || _pending.isNotEmpty)
                _StatusLine(state: s, pending: _pending),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.loading, required this.onOpen, required this.onOpenFolder});

  final bool loading;
  final VoidCallback onOpen;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('ComicRedr', style: theme.textTheme.displaySmall),
          const SizedBox(height: 24),
          if (loading)
            const CircularProgressIndicator()
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onOpen,
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
            'Press o for a CBZ or PDF, O for a folder of pages, or drop either here. Press ? for the keymap.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
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
    final within = stops > 0 ? (state.panelIndex + 1) / stops : 1.0;
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
  const _StatusLine({required this.state, required this.pending});

  /// Where guided view is on the page, or why it shows the whole page.
  static String _guided(ReaderState s) {
    final found = s.panels[s.page];
    if (found == null) return 'guided: finding panels…';
    final stops = s.stopsOn(s.page);
    if (stops.isEmpty) return 'guided: whole page (${found.gate.reasons.first})';
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
    final left = [
      if (book != null) book.title,
      if (book != null) pages,
      if (book != null && state.guided) _guided(state),
      if (book != null && !state.guided && state.mode == PageMode.spread) 'spread',
      if (state.rightToLeft) 'RTL',
    ].join('  ·  ');
    return Container(
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(state.message ?? left, key: const Key('status'), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text(
            pending,
            key: const Key('pending'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          if (book != null) ...[
            const SizedBox(width: 12),
            Text(p.basename(book.path), style: theme.textTheme.bodySmall),
          ],
        ],
      ),
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
        child: ListView(
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
      ),
    );
  }
}
