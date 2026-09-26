import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/reader_notifier.dart';
import '../version.dart';
import 'library_detection.dart';
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
                OutlinedButton.icon(
                  key: const Key('settingsEmpty'),
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Settings'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${Platform.isAndroid ? 'A Comics folder on the phone' : 'A Comics folder in your home'} '
              'joins the library by itself when ComicRedr starts. '
              'A adds any other folder of comics. o opens a CBZ or PDF and O a folder of pages '
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

/// The library pass on the status line, after the book count.
String describeDetection(DetectionStatus d) {
  if (d.paused) return '  ·  Finding panels paused';
  if (!d.running || d.total == 0) return '';
  return '  ·  Finding panels: ${d.done} / ${d.total} pages${d.book == null ? '' : ' (${d.book})'}';
}

/// The library's status line: a notice, the scan's progress, or a count.

class LibraryStatus extends ConsumerWidget {
  const LibraryStatus({super.key, required this.books, required this.pending, required this.onFailures});

  final List<LibraryBook> books;
  final String pending;
  final VoidCallback onFailures;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reader = ref.watch(readerProvider);
    final scan = ref.watch(scanStatusProvider).value ?? const ScanStatus();
    final detect = ref.watch(detectionStatusProvider).value ?? const DetectionStatus();
    final series = books.map((b) => b.seriesId).toSet().length;
    final text =
        reader.message ??
        (scan.running
            ? scan.total == 0
                  ? 'Scanning the library folders…'
                  : 'Scanning: ${scan.done} / ${scan.total} new or changed books'
            : '${books.length} books in $series series'
                  '${scan.failed.isEmpty ? '' : '  ·  ${scan.failed.length} could not be read'}'
                  '${describeDetection(detect)}');
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
                  if (detect.running || detect.paused)
                    IconButton(
                      key: const Key('detect-pause'),
                      tooltip: detect.paused ? 'Go on finding panels' : 'Pause finding panels',
                      icon: Icon(detect.paused ? Icons.play_arrow : Icons.pause),
                      onPressed: () {
                        final d = ref.read(libraryDetectionProvider);
                        detect.paused ? d.resume() : d.pause();
                      },
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
