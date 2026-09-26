import 'dart:async';

import 'package:comic_formats/comic_formats.dart' show naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_store.dart';
import 'providers.dart';

/// Asks for a collection to put [book] in: one of those there are, or a
/// new name.
Future<String?> askCollection(BuildContext context, WidgetRef ref, LibraryBook book) {
  final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
  final names = {for (final b in all) ...b.collections}.difference(book.collections.toSet()).toList()
    ..sort(naturalCompare);
  return showDialog<String>(
    context: context,
    builder: (_) => CollectionDialog(book: book, names: names),
  );
}

class CollectionDialog extends StatefulWidget {
  const CollectionDialog({super.key, required this.book, required this.names});

  final LibraryBook book;

  /// Collections the book is not in yet.
  final List<String> names;

  @override
  State<CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<CollectionDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done(String name) {
    if (name.trim().isNotEmpty) Navigator.pop(context, name.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add ${widget.book.name} to a collection'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('collectionName'),
            controller: _field,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'New collection'),
            onSubmitted: _done,
          ),
          if (widget.names.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [for (final n in widget.names) ActionChip(label: Text(n), onPressed: () => _done(n))],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => _done(_field.text), child: const Text('Add')),
    ],
  );
}
