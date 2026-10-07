import 'dart:async';

import 'package:comic_formats/comic_formats.dart' show naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../hotkeys.dart';
import 'library_store.dart';
import 'providers.dart';

/// The one collection question of the app, so that the keyboard can find it
/// from wherever it was asked ([askCollection]).
final collectionAskerProvider = Provider<CollectionAsker>((ref) => CollectionAsker());

/// Asks for a collection to put the comics [keys] (content keys) in: one of
/// those there are, or a new name; null when the question was left. [what]
/// names them in the dialog's title, a comic's name or how many comics.
///
/// Every `gc` and every Collection button asks through here, in the library
/// (a cover, the marked comics, the details pane or page) as in the reader
/// (the open comic, t563), so they offer the same names and all take a name
/// typed before the dialog shows. The dialog's route is pushed in this very
/// call, nothing awaited first, so call it before the caller's first await.
///
/// Offered is every collection there is ([LibraryStore.collectionNames]),
/// less the ones every one of [keys] is in already. That is read from the
/// rows, not the library's list of books, since neither an open comic nor
/// the comics in a collection need be in a library folder.
Future<String?> askCollection(
  BuildContext context,
  WidgetRef ref, {
  required String what,
  required Iterable<String> keys,
}) {
  final store = ref.read(libraryStoreProvider);
  final wanted = keys.toSet();
  return ref.read(collectionAskerProvider).ask(context, what: what, later: () => _offered(store, wanted));
}

/// The name [askCollection] gives [books] in the dialog's title.
String collectionWhat(List<LibraryBook> books) => books.length == 1 ? books.single.name : '${books.length} comics';

Future<List<String>> _offered(LibraryStore store, Set<String> keys) async {
  final inAll = await store.collectionsOfAll(keys);
  return [
    for (final name in await store.collectionNames())
      if (!inAll.contains(name)) name,
  ];
}

/// Asks the collection question and knows the one that is up:
/// ReaderKeyboard hands it the keys typed before the dialog's field has
/// the focus ([typed], through `HomeScreen._typeAhead`).
class CollectionAsker {
  /// The question asked last. Whether it is still open is the question's
  /// own to say ([CollectionQuestion.open]), nothing is kept here about it.
  CollectionQuestion? _last;

  CollectionQuestion? get _open => (_last?.open ?? false) ? _last : null;

  /// Shows the question for [what] and answers with the name picked or
  /// typed, null when it was left. [later] reads the names to offer, once
  /// the dialog is on its way.
  ///
  /// Nothing here refuses a second question while one is up, because no
  /// input gets that far: every asker sits under ReaderKeyboard, which
  /// gives each key to [typed] first while a question is open (so neither
  /// `gc` nor Enter or Space on a focused button arrives), and the
  /// Navigator absorbs pointers from the push until the dialog's barrier
  /// covers the buttons. Were code to ask twice all the same, the second
  /// dialog would lie over the first, each with its own answer, and
  /// [typed] would go to the one on top.
  Future<String?> ask(BuildContext context, {required String what, required Future<List<String>> Function() later}) =>
      (_last = CollectionQuestion(context, what: what, later: later())).answer;

  /// A key pressed on the app's keyboard: true when a question is open, so
  /// the key was typed into it and is no command.
  bool typed(KeyEvent event) {
    final question = _open;
    if (question == null) return false;
    question.typed(event);
    return true;
  }
}

/// One asking of the collection question ([CollectionAsker.ask]). The
/// dialog's route is pushed at once, with nothing awaited first: the names
/// to offer are a query, so they come as [later] and the dialog fills its
/// chips in when they are there.
///
/// Even so the dialog's field only has the focus a frame or more after
/// the key press, and the first dialog of a run takes its time to build.
/// Until then keys still arrive at the app's keyboard, which hands them
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
      builder: (_) => CollectionDialog(what: what, later: later, field: _field),
    );
    answer = navigator.push(_route);
    // The field is the dialog's until its route is gone, closing animation
    // included.
    unawaited(_route.completed.whenComplete(_field.dispose));
  }

  final _field = TextEditingController();
  late final DialogRoute<String> _route;

  /// The name picked or typed; null when the dialog was left.
  late final Future<String?> answer;

  /// Not answered yet: keys and touches are the dialog's, not commands.
  /// The route is the only one who knows: it is active from the push until
  /// it is popped, however that came about (Enter, a chip, a button, Esc, a
  /// click beside the dialog, [typed]), and [answer] completes in that pop.
  bool get open => _route.isActive;

  /// A key pressed on the app's keyboard while the question is [open], so
  /// before the field had the focus: a character goes on the end of the
  /// name (a capital with Shift, a space, a held key's repeats, as the
  /// field would take them), Backspace takes one off, Enter answers with
  /// the name (as in the field, an empty one is no answer) and Esc leaves.
  ///
  /// Dropped, since they must not act on what is behind the dialog and
  /// there is no cursor or selection yet: an arrow, Tab, Delete and the
  /// function keys (some platforms send Tab and Delete as the control
  /// characters U+0009 and U+007F, which are no part of a name), and a key
  /// with Ctrl, Alt or Meta held (Ctrl+V does not paste here).
  ///
  /// Also lost, and not to be had here: an accent typed with a dead key or
  /// the Compose key. The input method only puts those together for a text
  /// field that has the focus; until then the dead key comes alone, with
  /// no character, and the letter after it plain, so `´` `e` gives `e`.
  void typed(KeyEvent event) {
    if (!open || event is KeyUpEvent) return;
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
        if (ch.runes.any((r) => r < 0x20 || r == 0x7f)) return;
        _set(name + ch);
    }
  }

  void _set(String name) => _field.value = TextEditingValue(
    text: name,
    selection: TextSelection.collapsed(offset: name.length),
  );

  /// Answers before the dialog was ever built: popping the route ends
  /// [open], so from here on keys are commands again.
  void _close(String? name) {
    if (_route.isCurrent) _route.navigator?.pop(name);
  }
}

class CollectionDialog extends StatefulWidget {
  const CollectionDialog({super.key, required this.what, required this.later, required this.field});

  /// The comic's name, or how many comics.
  final String what;

  /// Collections the comics are not all in yet, still being read when the
  /// dialog shows: its chips, in name order, once they are there. When
  /// reading them fails the dialog says so where the chips would be, and a
  /// typed name still works.
  final Future<List<String>> later;

  /// The name field's text, kept by the [CollectionQuestion], which puts
  /// the keys typed before the dialog was up in it and disposes of it.
  final TextEditingController field;

  @override
  State<CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<CollectionDialog> {
  TextEditingController get _field => widget.field;
  List<String> _names = const [];

  /// Why the collections there are could not be read, to say so.
  Object? _failed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final names = [...await widget.later]..sort(naturalCompare);
      if (mounted) setState(() => _names = names);
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    }
  }

  void _done(String name) {
    if (name.trim().isNotEmpty) Navigator.pop(context, name.trim());
  }

  @override
  Widget build(BuildContext context) => DialogHotkeys(
    child: AlertDialog(
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
        TextButton(onPressed: () => Navigator.pop(context), child: const Mnemonic('Cancel')),
        FilledButton(
          key: const Key('collectionAdd'),
          onPressed: () => _done(_field.text),
          child: const Mnemonic('Add'),
        ),
      ],
    ),
  );
}
