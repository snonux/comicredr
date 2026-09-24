import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../library/library_store.dart';
import 'reader_notifier.dart';
import 'thumbnails.dart';

/// The open book's bookmarks and marks (`M`, or the list button on the
/// status line), in reading order, each with a picture of its page and its
/// note. Arrows and `hjkl` move the selection, Enter, a click or a tap
/// jumps there, `e` writes a note, `x` or Delete removes it, Esc closes.
/// The row the list opens on is the last bookmark at or before the page
/// being read.
class BookmarkList extends ConsumerStatefulWidget {
  const BookmarkList({super.key, required this.onClose, this.onDialogDone});

  final VoidCallback onClose;

  /// Called when the note dialog closes, to hand the keys back.
  final VoidCallback? onDialogDone;

  @override
  ConsumerState<BookmarkList> createState() => BookmarkListState();
}

class BookmarkListState extends ConsumerState<BookmarkList> {
  final _scroll = ScrollController();
  int _selected = 0;
  bool _placed = false;
  bool _asking = false;

  static const _rowHeight = 88.0;

  @override
  void initState() {
    super.initState();
    final s = ref.read(readerProvider);
    final before = s.bookmarks.lastIndexWhere((b) => b.page <= s.page);
    _selected = before < 0 ? 0 : before;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<BookmarkInfo> get _all => ref.read(readerProvider).bookmarks;

  /// List intents while it is open; everything else is swallowed, so a key
  /// meant for the page does nothing behind the list.
  void handle(ReaderCommand c) {
    if (_asking) return;
    final n = _all.length;
    switch (c.intent) {
      case ReaderIntent.back:
      case ReaderIntent.bookmarkList:
        widget.onClose();
      case _ when n == 0:
        break;
      case ReaderIntent.nextStep:
      case ReaderIntent.panDown:
      case ReaderIntent.nextBookmark:
        _select(_selected + c.times);
      case ReaderIntent.prevStep:
      case ReaderIntent.panUp:
      case ReaderIntent.prevBookmark:
        _select(_selected - c.times);
      case ReaderIntent.firstPage:
        _select(0);
      case ReaderIntent.lastPage:
        _select(c.count != null ? c.count! - 1 : n - 1);
      case ReaderIntent.activate:
        _jump(_all[_selected.clamp(0, n - 1)]);
      case ReaderIntent.editBook:
        unawaited(_note(_all[_selected.clamp(0, n - 1)]));
      case ReaderIntent.remove:
      case ReaderIntent.bookmark:
        _remove(_all[_selected.clamp(0, n - 1)]);
      default:
        break;
    }
  }

  void _select(int i) {
    final n = _all.length;
    if (n == 0) return;
    setState(() => _selected = i.clamp(0, n - 1));
    _reveal();
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _selected * _rowHeight;
    final view = _scroll.position.viewportDimension;
    final at = _scroll.offset;
    final to = top < at ? top : (top + _rowHeight > at + view ? top + _rowHeight - view : null);
    if (to != null) _scroll.jumpTo(to.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  void _jump(BookmarkInfo b) {
    ref.read(readerProvider.notifier).jumpToBookmark(b);
    widget.onClose();
  }

  void _remove(BookmarkInfo b) {
    unawaited(ref.read(readerProvider.notifier).removeBookmark(b.id));
    ref.read(readerProvider.notifier).notice('Removed the ${b.mark == null ? 'bookmark' : "mark '${b.mark}"} on ${describePlace(b)}');
  }

  Future<void> _note(BookmarkInfo b) async {
    _asking = true;
    try {
      final note = await askBookmarkNote(context, b);
      if (note != null) await ref.read(readerProvider.notifier).setBookmarkNote(b.id, note);
    } finally {
      _asking = false;
      widget.onDialogDone?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    final thumbs = ref.watch(thumbnailsProvider);
    final theme = Theme.of(context);
    final all = s.bookmarks;
    if (_selected >= all.length && all.isNotEmpty) _selected = all.length - 1;
    if (!_placed && all.isNotEmpty) {
      _placed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal();
      });
    }
    return Material(
      key: const Key('bookmarkList'),
      color: Colors.black.withValues(alpha: 0.92),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Bookmarks  ·  ${s.book?.title ?? ''}',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const Key('bookmarkListClose'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close (Esc)',
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: all.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No bookmarks in this book yet. mm or the bookmark button bookmarks the page, '
                        'or the panel in guided view; ma sets mark a.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: _rowHeight,
                    itemCount: all.length,
                    itemBuilder: (context, i) => _Row(
                      key: ValueKey(all[i].id),
                      index: i,
                      bookmark: all[i],
                      thumbs: thumbs,
                      selected: i == _selected,
                      current: s.unit.contains(all[i].page),
                      onTap: () => _jump(all[i]),
                      onNote: () => unawaited(_note(all[i])),
                      onRemove: () => _remove(all[i]),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Enter jumps  ·  e adds a note  ·  x removes  ·  } { step through them in the book',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.index,
    required this.bookmark,
    required this.thumbs,
    required this.selected,
    required this.current,
    required this.onTap,
    required this.onNote,
    required this.onRemove,
  });

  final int index;
  final BookmarkInfo bookmark;
  final Thumbnails? thumbs;
  final bool selected;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onNote;
  final VoidCallback onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  ImageProvider? _image;

  static const _thumbWidth = 48.0;

  @override
  void initState() {
    super.initState();
    final page = widget.bookmark.page;
    unawaited(
      widget.thumbs?.get(page).then((path) {
        if (path == null || !mounted) return;
        final px = (_thumbWidth * MediaQuery.devicePixelRatioOf(context)).round();
        setState(() => _image = ResizeImage(FileImage(File(path)), width: px, policy: ResizeImagePolicy.fit));
      }),
    );
  }

  @override
  void dispose() {
    widget.thumbs?.cancel(widget.bookmark.page);
    unawaited(_image?.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final b = widget.bookmark;
    final i = widget.index;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: widget.selected ? Border.all(color: Colors.amber, width: 3) : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        key: Key('bookmarkRow-$i'),
        onTap: widget.onTap,
        canRequestFocus: false,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Container(
              width: _thumbWidth,
              height: 72,
              color: Colors.white10,
              child: _image == null
                  ? const Icon(Icons.image_outlined, color: Colors.white24)
                  : Image(image: _image!, fit: BoxFit.contain, gaplessPlayback: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (b.mark == null)
                        Icon(Icons.bookmark, size: 18, color: scheme.primary)
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          color: scheme.secondaryContainer,
                          child: Text(b.mark!, style: TextStyle(color: scheme.onSecondaryContainer)),
                        ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          describePlace(b).replaceFirst('p', 'P'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: widget.current ? scheme.primary : null,
                            fontWeight: widget.current ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    b.note ?? (b.mark == null ? 'No note' : "Mark '${b.mark}: no note"),
                    key: Key('bookmarkNoteText-$i'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: b.note == null
                        ? theme.textTheme.bodySmall?.copyWith(color: Colors.white38, fontStyle: FontStyle.italic)
                        : theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            IconButton(
              key: Key('bookmarkNote-$i'),
              icon: const Icon(Icons.edit_note),
              tooltip: 'Note (e)',
              onPressed: widget.onNote,
            ),
            IconButton(
              key: Key('bookmarkRemove-$i'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove (x)',
              onPressed: widget.onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a short note on bookmark [b]; null when cancelled, empty to
/// take the note off.
Future<String?> askBookmarkNote(BuildContext context, BookmarkInfo b) =>
    showDialog<String>(context: context, builder: (_) => _NoteDialog(bookmark: b));

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.bookmark});

  final BookmarkInfo bookmark;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  // Owned here, so it outlives the closing animation.
  late final _field = TextEditingController(text: widget.bookmark.note ?? '');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Note on ${describePlace(widget.bookmark)}'),
    content: TextField(
      key: const Key('bookmarkNoteField'),
      controller: _field,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(hintText: 'A few words to find it by'),
      onSubmitted: (text) => Navigator.pop(context, text),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const Key('bookmarkNoteSave'),
        onPressed: () => Navigator.pop(context, _field.text),
        child: const Text('Save'),
      ),
    ],
  );
}
