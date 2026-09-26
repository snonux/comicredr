import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/meta_edits.dart';
import '../data/sidecar_sync.dart';
import '../reader/reader_notifier.dart';
import 'library_store.dart';
import 'providers.dart';

/// `e` on a book, or Edit in its details: asks for new facts and saves
/// them. Edits go in the index and the book's sidecar; the comic file is
/// never rewritten, so its content key, and with it everything else the
/// app knows about it, stays the same.
Future<void> editBook(BuildContext context, WidgetRef ref, LibraryBook book) async {
  final messenger = ScaffoldMessenger.of(context);
  // Read before the dialog: the widget [ref] belongs to may be gone after.
  final save = _saver(ref);
  final edits = await showDialog<Map<MetaField, MetaEdit>>(
    context: context,
    builder: (_) => EditBookDialog(book: book),
  );
  if (edits == null || edits.isEmpty) return;
  try {
    await save([book], edits);
    messenger.showSnackBar(const SnackBar(content: Text('Saved')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save the changes to ${book.name}: $e')));
  }
}

/// `e` on a series: renames it, which is an edit to every book in it.
Future<void> renameSeries(BuildContext context, WidgetRef ref, LibrarySeries series) async {
  final messenger = ScaffoldMessenger.of(context);
  final save = _saver(ref);
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameSeriesDialog(series: series),
  );
  if (name == null || name == series.name) return;
  try {
    final at = DateTime.now();
    await save(series.books, {MetaField.series: MetaEdit(name, at: at)});
    final n = series.books.length;
    messenger.showSnackBar(SnackBar(content: Text('Renamed $n ${n == 1 ? 'book' : 'books'} to $name')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not rename ${series.name}: $e')));
  }
}

/// Saves edits to books in the index, then writes their sidecars.
Future<void> Function(List<LibraryBook>, Map<MetaField, MetaEdit>) _saver(WidgetRef ref) {
  final store = ref.read(libraryStoreProvider);
  final sidecars = ref.read(sidecarSyncProvider);
  return (books, edits) => _save(store, sidecars, books, edits);
}

Future<void> _save(
  LibraryStore store,
  SidecarSync sidecars,
  List<LibraryBook> books,
  Map<MetaField, MetaEdit> edits,
) async {
  for (final b in books) {
    await store.editBook(b.key, edits);
  }
  for (final b in books) {
    await sidecars.writeBeside(b.path, b.key, folder: b.isFolder);
  }
}

/// The edit form: one field per fact, filled with what the library shows.
/// An edited fact has an undo button that brings the file's own value back.
class EditBookDialog extends StatefulWidget {
  const EditBookDialog({super.key, required this.book});

  final LibraryBook book;

  @override
  State<EditBookDialog> createState() => _EditBookDialogState();
}

class _EditBookDialogState extends State<EditBookDialog> {
  late final _fields = {for (final f in MetaField.values) f: TextEditingController(text: widget.book.fact(f) ?? '')};

  /// Facts put back to the file's value with the undo button.
  final _undone = <MetaField>{};
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _undo(MetaField f) => setState(() {
    _undone.add(f);
    _fields[f]!.text = widget.book.fromFile[f] ?? '';
  });

  void _save() {
    if (!_form.currentState!.validate()) return;
    final at = DateTime.now();
    final edits = <MetaField, MetaEdit>{};
    for (final f in MetaField.values) {
      final text = _fields[f]!.text.trim();
      final file = widget.book.fromFile.containsKey(f) ? widget.book.fromFile[f] ?? '' : null;
      if (_undone.contains(f) && text == file) {
        edits[f] = MetaEdit.undo(at: at);
      } else if (f == MetaField.series && text.isEmpty) {
        // A book always has a series: a blank one means the file's again.
        if (widget.book.fromFile.containsKey(f)) {
          edits[f] = MetaEdit.undo(at: at);
        }
      } else if (text != (widget.book.fact(f) ?? '')) {
        edits[f] = MetaEdit(text.isEmpty ? null : text, at: at);
      }
    }
    Navigator.pop(context, edits);
  }

  Widget _field(MetaField f, {bool autofocus = false}) {
    final edited = widget.book.fromFile.containsKey(f) && !_undone.contains(f);
    final file = widget.book.fromFile[f];
    return TextFormField(
      key: Key('edit.${f.name}'),
      controller: _fields[f],
      autofocus: autofocus,
      minLines: f == MetaField.summary ? 2 : 1,
      maxLines: f == MetaField.summary ? 6 : 1,
      keyboardType: f.numeric ? TextInputType.number : null,
      textInputAction: f == MetaField.summary ? TextInputAction.newline : TextInputAction.next,
      onChanged: (_) {
        if (_undone.remove(f)) setState(() {});
      },
      onFieldSubmitted: f == MetaField.summary ? null : (_) => _save(),
      validator: (v) =>
          f.numeric && v != null && v.trim().isNotEmpty && int.tryParse(v.trim()) == null ? 'A whole number' : null,
      decoration: InputDecoration(
        labelText: f.label,
        helperText: switch (f) {
          MetaField.writers || MetaField.artists => 'Separate names with commas',
          _ => null,
        },
        suffixIcon: edited
            ? IconButton(
                key: Key('undo.${f.name}'),
                icon: const Icon(Icons.undo),
                tooltip: file == null ? 'Undo: the file says nothing' : 'Undo: the file says $file',
                onPressed: () => _undo(f),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final edited = widget.book.fromFile.isNotEmpty;
    return AlertDialog(
      key: const Key('editDialog'),
      title: Text('Edit ${widget.book.name}'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(MetaField.series, autofocus: true),
                Row(
                  children: [
                    Expanded(child: _field(MetaField.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _field(MetaField.volume)),
                    const SizedBox(width: 12),
                    Expanded(child: _field(MetaField.year)),
                  ],
                ),
                _field(MetaField.title),
                _field(MetaField.writers),
                _field(MetaField.artists),
                _field(MetaField.summary),
                const SizedBox(height: 12),
                Text(
                  'Changes are kept in the file beside the comic and travel with it. '
                  'The comic itself is not changed.${edited ? ' Undo puts back what the comic says.' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(key: const Key('editCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('editSave'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _RenameSeriesDialog extends StatefulWidget {
  const _RenameSeriesDialog({required this.series});

  final LibrarySeries series;

  @override
  State<_RenameSeriesDialog> createState() => _RenameSeriesDialogState();
}

class _RenameSeriesDialogState extends State<_RenameSeriesDialog> {
  late final _field = TextEditingController(text: widget.series.name);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() {
    final name = _field.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.series.books.length;
    return AlertDialog(
      key: const Key('renameSeriesDialog'),
      title: Text('Rename ${widget.series.name}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('seriesName'),
              controller: _field,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Series'),
              onSubmitted: (_) => _done(),
            ),
            const SizedBox(height: 12),
            Text(
              'Sets the series of all $n ${n == 1 ? 'book' : 'books'} in it. A name another series has '
              'already puts them together.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('renameSave'), onPressed: _done, child: const Text('Rename')),
      ],
    );
  }
}
