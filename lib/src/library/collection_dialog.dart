import 'dart:async';

import 'package:comic_formats/comic_formats.dart' show naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_store.dart';
import 'providers.dart';

/// Asks for a collection to put [books] in: one of those there are, or a
/// new name. A collection every one of them is in already is not offered.
Future<String?> askCollection(BuildContext context, WidgetRef ref, List<LibraryBook> books) {
  final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
  final names = {for (final b in all) ...b.collections}.where((n) => !books.every((b) => b.collections.contains(n)));
  return showCollectionDialog(
    context,
    what: books.length == 1 ? books.single.name : '${books.length} comics',
    names: names,
  );
}

/// The collection question itself, for [what] (a comic's name, or how many
/// comics), offering [names] in name order. The library asks through
/// [askCollection]; the reader (`gc` on the open comic) through a
/// [CollectionQuestion], which also takes the keys typed before the dialog
/// has the focus.
Future<String?> showCollectionDialog(BuildContext context, {required String what, required Iterable<String> names}) =>
    showDialog<String>(
      context: context,
      builder: (_) => CollectionDialog(what: what, names: names.toList()..sort(naturalCompare)),
    );

/// The collection question as the reader asks it (`gc` on the open comic,
/// t563). The dialog's route is pushed at once, with nothing awaited
/// first: the names to offer are a query, an open comic need not be in the
/// library's list of books, so they come as [later] and the dialog fills
/// its chips in when they are there.
///
/// Even so the dialog's field only has the focus a frame or more after
/// the key press, and the first dialog of a run takes its time to build.
/// Until then keys still arrive at the reader's keyboard, which hands them
/// to [typed] for as long as the question is [open]: none of them is a
/// command, and what was typed is in the field when the dialog shows.
class CollectionQuestion {
  CollectionQuestion(BuildContext context, {required String what, required Future<List<String>> later}) {
    final navigator = Navigator.of(context, rootNavigator: true);
    // Answered before the dialog was built, nobody is left to hear that
    // reading the names failed.
    later.ignore();
    _route = DialogRoute<String>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => CollectionDialog(what: what, names: const [], later: later, field: _field),
    );
    answer = navigator.push(_route).whenComplete(() => _open = false);
    // The field is the dialog's until its route is gone, closing animation
    // included.
    unawaited(_route.completed.whenComplete(_field.dispose));
  }

  final _field = TextEditingController();
  late final DialogRoute<String> _route;
  bool _open = true;

  /// The name picked or typed; null when the dialog was left.
  late final Future<String?> answer;

  /// Not answered yet: keys and touches are the dialog's, not commands.
  bool get open => _open;

  /// A key pressed on the reader's keyboard while the question is [open],
  /// so before the field had the focus: a character goes on the end of the
  /// name, Backspace takes one off, Enter answers with the name (as in the
  /// field, an empty one is no answer) and Esc leaves. Any other key (an
  /// arrow, Tab, a function key) is dropped: it must not turn the page
  /// behind the dialog, and there is no cursor to move yet.
  void typed(KeyEvent event) {
    if (!_open || event is KeyUpEvent) return;
    final name = _field.text;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _close(null);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (name.trim().isNotEmpty) _close(name.trim());
      case LogicalKeyboardKey.backspace:
        if (name.isNotEmpty) _set(name.characters.skipLast(1).string);
      default:
        final keys = HardwareKeyboard.instance;
        final ch = event.character;
        if (ch == null || keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return;
        // Control characters (Tab, Delete) come as characters on some platforms.
        if (ch.runes.any((r) => r < 0x20 || r == 0x7f)) return;
        _set(name + ch);
    }
  }

  void _set(String name) => _field.value = TextEditingValue(
    text: name,
    selection: TextSelection.collapsed(offset: name.length),
  );

  /// Answers before the dialog was ever built; from here on keys are
  /// commands again.
  void _close(String? name) {
    _open = false;
    if (_route.isCurrent) _route.navigator?.pop(name);
  }
}

class CollectionDialog extends StatefulWidget {
  const CollectionDialog({super.key, required this.what, required this.names, this.later, this.field});

  /// The comic's name, or how many comics.
  final String what;

  /// Collections the books are not all in yet.
  final List<String> names;

  /// More of them, still being read when the dialog shows: they take the
  /// place of [names] once there. When reading them fails the dialog says
  /// so where the chips would be, and a typed name still works.
  final Future<List<String>>? later;

  /// The name field's text, when the caller keeps it (a [CollectionQuestion]
  /// puts the keys typed before the dialog was up in it); else the dialog
  /// has its own.
  final TextEditingController? field;

  @override
  State<CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<CollectionDialog> {
  late final _own = widget.field == null ? TextEditingController() : null;
  TextEditingController get _field => widget.field ?? _own!;
  late List<String> _names = widget.names;

  /// Why the collections there are could not be read, to say so.
  Object? _failed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final later = widget.later;
    if (later == null) return;
    try {
      final names = [...await later]..sort(naturalCompare);
      if (mounted) setState(() => _names = names);
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _done(String name) {
    if (name.trim().isNotEmpty) Navigator.pop(context, name.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('collectionDialog'),
    title: Text('Add ${widget.what} to a collection'),
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
          if (_failed case final e?) ...[
            const SizedBox(height: 12),
            Text('Could not list your collections: $e', key: const Key('collectionsFailed')),
          ] else if (_names.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [for (final n in _names) ActionChip(label: Text(n), onPressed: () => _done(n))],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const Key('collectionAdd'), onPressed: () => _done(_field.text), child: const Text('Add')),
    ],
  );
}
