import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reader_input/reader_input.dart';

import '../hotkeys.dart';
import '../reader/reader_notifier.dart';
import '../version.dart';
import 'library_store.dart';
import 'providers.dart';
import 'scanner.dart';

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({
    super.key,
    required this.onAddRoot,
    required this.onOpenFile,
    required this.onOpenFolder,
    required this.onSettings,
  });

  final VoidCallback onAddRoot;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenFolder;
  final VoidCallback onSettings;

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
            // The labels stay as short as a phone needs; the tooltips name the keys.
            Tooltip(
              message: KeyHints.tip(context, 'Add a folder to the library', ReaderIntent.addRoot),
              child: FilledButton.icon(
                key: const Key('addRootEmpty'),
                onPressed: onAddRoot,
                icon: const Icon(Icons.create_new_folder),
                label: const Text('Add your comics folder'),
              ),
            ),
            const SizedBox(height: 12),
            _otherWays(context),
            const SizedBox(height: 12),
            _help(theme),
          ],
        ),
      ),
    );
  }

  /// The ways in besides adding a library folder, and Settings. Their
  /// labels stay short for a phone, so each key is in a tooltip.
  Widget _otherWays(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    alignment: WrapAlignment.center,
    children: [
      Tooltip(
        message: KeyHints.tip(context, 'Open a comic without adding it', ReaderIntent.openFile),
        child: OutlinedButton.icon(
          onPressed: onOpenFile,
          icon: const Icon(Icons.menu_book),
          label: const Text('Open a comic'),
        ),
      ),
      Tooltip(
        message: KeyHints.tip(context, 'Open a folder of pages as a book', ReaderIntent.openFolder),
        child: OutlinedButton.icon(
          onPressed: onOpenFolder,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open a folder'),
        ),
      ),
      Tooltip(
        message: KeyHints.tip(context, 'Settings', ReaderIntent.showSettings),
        child: OutlinedButton.icon(
          key: const Key('settingsEmpty'),
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Settings'),
        ),
      ),
    ],
  );

  /// The paragraph under the buttons: what joins the library by itself,
  /// and the keys (fixed text, not read from the keymap).
  Widget _help(ThemeData theme) => Text(
    '${Platform.isAndroid ? 'A Comics folder in the device\'s storage' : 'A Comics folder in your home'} '
    'joins the library by itself when ComicRedr starts. '
    'A adds any other folder of comics. o opens a CBZ or PDF and O a folder of pages '
    'without adding them. Or drop either here. ? shows the keymap.',
    textAlign: TextAlign.center,
    style: theme.textTheme.bodyMedium,
  );
}

/// The library's status line: a notice, the scan's progress, or a count.

class LibraryStatus extends ConsumerWidget {
  const LibraryStatus({super.key, required this.books, required this.pending, required this.onFailures});

  final List<LibraryBook> books;
  final String pending;
  final VoidCallback onFailures;

  /// What the line says when there is no notice: how far the scan is, or
  /// what the library holds and how much of it could not be read.
  String _count(ScanStatus scan) {
    if (scan.running) {
      return scan.total == 0
          ? 'Scanning the library folders…'
          : 'Scanning: ${scan.done} / ${scan.total} new or changed books';
    }
    final series = books.map((b) => b.seriesId).toSet().length;
    return '${books.length} books in $series series'
        '${scan.failed.isEmpty ? '' : '  ·  ${scan.failed.length} could not be read'}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reader = ref.watch(readerProvider);
    final scan = ref.watch(scanStatusProvider).value ?? const ScanStatus();
    final text = reader.message ?? _count(scan);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reader.loading || (scan.running && scan.total > 0))
            LinearProgressIndicator(minHeight: 2, value: reader.loading ? null : scan.done / math.max(1, scan.total)),
          // A tap on the count of unread files lists them; so does its key.
          InkWell(
            onTap: scan.failed.isEmpty ? null : onFailures,
            child: Tooltip(
              message: scan.failed.isEmpty
                  ? ''
                  : KeyHints.tip(context, 'Which comics could not be read, and why', ReaderIntent.showScanFailures),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: LayoutBuilder(builder: (context, box) => _line(context, theme, text, box.maxWidth)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The line itself: what [text] says, the keys typed so far and the
  /// version. The version is left out when it would take more than half
  /// the [width], as with the system's text at twice its size or more on a
  /// phone, where it pushed the line past the screen's edge (w73); what the
  /// line says comes first. The version is also on the `?` help.
  Widget _line(BuildContext context, ThemeData theme, String text, double width) {
    final version = 'ComicRedr $appVersion';
    final style = theme.textTheme.bodySmall;
    final painter = TextPainter(
      text: TextSpan(text: version, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final showVersion = painter.width + 12 <= width / 2;
    painter.dispose();
    return Row(
      children: [
        Expanded(
          child: Text(text, key: const Key('status'), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        // A count or a key sequence: a few letters, never cut.
        Text(
          pending,
          key: const Key('pending'),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        if (showVersion) ...[const SizedBox(width: 12), Text(version, key: const Key('version'), style: style)],
      ],
    );
  }
}
