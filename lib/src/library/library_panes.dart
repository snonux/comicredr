import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/guided.dart';
import '../reader/reader_notifier.dart';
import 'cover_card.dart';
import 'default_folder.dart';
import 'edit_dialog.dart';
import 'library_store.dart';
import 'providers.dart';

/// Reading history: sittings with books, newest first, by day.
class HistoryPane extends ConsumerWidget {
  const HistoryPane({super.key, required this.books, required this.query, required this.onRead});

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

class SeriesDetail extends ConsumerWidget {
  const SeriesDetail({super.key, required this.series, required this.onRead, this.canRename = false});

  final LibrarySeries series;
  final void Function(LibraryBook, {Place? at}) onRead;

  /// A series, not a collection.
  final bool canRename;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final next = series.next;
    return ListView(
      key: const Key('detail'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(series.name, style: theme.textTheme.headlineSmall),
        Text('${series.books.length} books · ${series.read} read'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => onRead(next),
              icon: const Icon(Icons.chrome_reader_mode),
              label: Text('${next.inProgress ? 'Continue' : 'Read'} ${next.name}'),
            ),
            if (canRename)
              OutlinedButton.icon(
                key: const Key('renameSeries'),
                onPressed: () => renameSeries(context, ref, series),
                icon: const Icon(Icons.edit),
                label: const Text('Rename (e)'),
              ),
          ],
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
String folderCount(LibraryFolder folder) {
  final read = folder.books.where((b) => b.finished).length;
  return '${folder.books.length} ${folder.books.length == 1 ? 'book' : 'books'}${read > 0 ? ' · $read read' : ''}';
}

/// A folder's page: what is in it, a way in, and for a library folder a way
/// to take it out of the library.
class FolderDetail extends ConsumerWidget {
  const FolderDetail({super.key, required this.folder, required this.onOpen, required this.onRead, this.onBack});

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
            child: SizedBox(
              width: 200,
              height: 300,
              child: CoverImage(bookKey: folder.books.firstOrNull?.key, width: 512),
            ),
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
        Text(folderCount(folder), style: theme.textTheme.bodyMedium),
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
              onPressed: () => removeLibraryFolder(
                ref.read(libraryStoreProvider),
                ref.read(settingsStoreProvider),
                root.id,
                root.path,
              ),
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
