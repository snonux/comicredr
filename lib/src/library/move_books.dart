import 'dart:io';
import 'dart:isolate';

import 'package:comic_formats/comic_formats.dart' show firstVisit, naturalCompare;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/sidecar_sync.dart';
import '../hotkeys.dart';
import '../reader/reader_notifier.dart';
import 'bulk_actions.dart' show comicsCount;
import 'delete_book.dart';
import 'library_store.dart';
import 'providers.dart';

/// Moving comics to another folder of the library (`gm`, or Move in the
/// marks bar): a picker of the library's folders, typed into to narrow it,
/// with a way to make a new one; one question when comics of the same name
/// are there already. Each comic takes its sidecars along, and the index
/// follows it, so its position, panels, bookmarks and collections stay.

/// A folder the picker offers: its full [path] and how it is shown, the
/// library folder's name first (`Comics/Marvel/1980s`).
typedef MoveTarget = ({String path, String label});

/// Every folder under the library folders [roots], on disk, the empty ones
/// too: hidden folders, the folder books in [bookFolders] and what is in
/// them are left out. Symlinked folders are followed, each real folder
/// once. Runs on a short isolate, since a big library has many folders.
Future<List<MoveTarget>> moveTargets(List<String> roots, Set<String> bookFolders) =>
    Isolate.run(() => listMoveTargets(roots, bookFolders));

/// [moveTargets], on this isolate.
List<MoveTarget> listMoveTargets(List<String> roots, Set<String> bookFolders) {
  final seen = <String>{};
  final out = <MoveTarget>[];
  void walk(Directory dir, String label) {
    if (!firstVisit(dir, seen)) return;
    out.add((path: dir.path, label: label));
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: true);
    } on FileSystemException {
      return;
    }
    final subs = [
      for (final e in entries)
        if (e is Directory && !p.basename(e.path).startsWith('.') && !bookFolders.contains(e.path)) e,
    ]..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
    for (final d in subs) {
      walk(d, '$label/${p.basename(d.path)}');
    }
  }

  for (final r in roots) {
    final dir = Directory(r);
    if (dir.existsSync()) walk(dir, p.basename(p.normalize(r)));
  }
  return out;
}

/// Whether [target] matches what was typed in the picker: every word of
/// [query] somewhere in its label, case aside.
bool matchesTarget(MoveTarget target, String query) {
  final label = target.label.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(label.contains);
}

/// Moves [from] to [to], a file, a folder or a symlink (the link itself,
/// pointing where it did). A rename on one disk; across disks a copy, then
/// the original is deleted. Throws a [FileSystemException] when it can't,
/// leaving [from] as it was.
Future<void> movePath(String from, String to) async {
  final type = await FileSystemEntity.type(from, followLinks: false);
  if (type == FileSystemEntityType.link) {
    final target = await Link(from).target();
    // A relative link would point somewhere else from its new folder.
    await Link(to).create(p.isAbsolute(target) ? target : p.normalize(p.join(p.dirname(from), target)));
    await Link(from).delete();
    return;
  }
  try {
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
    return;
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode != 18) rethrow; // EXDEV: another disk.
  }
  final tmp = p.join(p.dirname(to), '.${p.basename(to)}.moving');
  try {
    await _copy(from, tmp);
    await (type == FileSystemEntityType.directory ? Directory(tmp) : File(tmp)).rename(to);
  } catch (_) {
    if (await FileSystemEntity.type(tmp, followLinks: false) != FileSystemEntityType.notFound) {
      await removePath(tmp);
    }
    rethrow;
  }
  await removePath(from);
}

Future<void> _copy(String from, String to) async {
  if (await FileSystemEntity.isDirectory(from)) {
    await Directory(to).create();
    await for (final e in Directory(from).list(followLinks: false)) {
      await _copy(e.path, p.join(to, p.basename(e.path)));
    }
  } else {
    await File(from).copy(to);
  }
}

/// Moves the comic at [from] into the folder [dir], keeping its name: the
/// comic, then its sidecars ([SidecarSync.moved]), then its row in the
/// index ([LibraryStore.moveFile]). If the comic can't be moved nothing
/// else changes. Returns where it went.
///
/// Close the book in the reader first, so nothing writes to it meanwhile.
Future<String> moveComic({
  required String from,
  required String dir,
  required String contentKey,
  required bool folder,
  required SidecarSync sidecars,
  required LibraryStore store,
}) async {
  final to = p.join(dir, p.basename(from));
  await sidecars.flush();
  await movePath(from, to);
  await sidecars.moved(from, to, contentKey, folder: folder);
  await store.moveFile(from, to);
  return to;
}

/// What to do with comics whose names are taken in the folder they go to.
enum MoveClash { cancel, skip, replace }

/// Moves [books] to a folder picked from the library's folders: `gm` with
/// comics marked or a cover selected, or Move in the marks bar. [current]
/// is the folder the Folders tab shows, picked first. Comics only on S3
/// have nothing here to move. [beforeMove] runs once a folder is picked.
/// Returns whether it went ahead.
Future<bool> moveLibraryBooks(
  BuildContext context,
  WidgetRef ref,
  List<LibraryBook> books, {
  String? current,
  void Function()? beforeMove,
}) async {
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);
  final sidecars = ref.read(sidecarSyncProvider), store = ref.read(libraryStoreProvider);
  final container = ProviderScope.containerOf(context);
  final roots = [for (final r in await store.roots()) r.path];
  final all = ref.read(booksProvider).value ?? const <LibraryBook>[];
  final targets = await moveTargets(roots, {
    for (final b in all)
      if (b.isFolder) b.path,
  });
  if (!context.mounted) return false;
  final what = todo.length == 1 ? todo.single.name : comicsCount(todo.length);
  final dir = await showDialog<String>(
    context: context,
    builder: (_) => MoveDialog(what: what, targets: targets, current: current),
  );
  if (dir == null || !context.mounted) return false;
  // Those already there stay as they are.
  final going = todo.where((b) => !p.equals(p.dirname(b.path), dir)).toList();
  if (going.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text('${todo.length == 1 ? 'It is' : 'They are'} there already')));
    return true;
  }
  final taken = [
    for (final b in going)
      if (await FileSystemEntity.type(p.join(dir, p.basename(b.path)), followLinks: false) !=
          FileSystemEntityType.notFound)
        b,
  ];
  var clash = MoveClash.replace;
  if (taken.isNotEmpty) {
    if (!context.mounted) return false;
    clash = await askMoveClash(context, taken.map((b) => p.basename(b.path)).toList(), dir);
    if (clash == MoveClash.cancel) return false;
  }
  final open = container.read(readerProvider).book?.key;
  if (open != null && going.any((b) => b.key == open)) await container.read(readerProvider.notifier).close();
  beforeMove?.call();
  final coverDir = container.read(coverDirProvider);
  var moved = 0, skipped = 0;
  final failed = <String>[];
  for (final b in going) {
    final to = p.join(dir, p.basename(b.path));
    if (taken.contains(b)) {
      if (clash == MoveClash.skip) {
        skipped++;
        continue;
      }
      try {
        // A comic in the library is deleted as one, so nothing is left of it.
        final there = all.where((o) => p.equals(o.path, to)).firstOrNull;
        if (there != null) {
          await deleteComic(
            path: to,
            contentKey: there.key,
            folder: there.isFolder,
            sidecars: sidecars,
            store: store,
            coverDir: coverDir,
          );
        } else {
          await removePath(to);
        }
      } on FileSystemException catch (e) {
        failed.add('${b.name}: ${e.message}');
        continue;
      }
    }
    try {
      await moveComic(from: b.path, dir: dir, contentKey: b.key, folder: b.isFolder, sidecars: sidecars, store: store);
      moved++;
    } on FileSystemException catch (e) {
      failed.add('${b.name}: ${e.message}');
    } catch (e) {
      // The comic went first, so this is a sidecar or the index; a scan
      // finds the comic at its new place.
      moved++;
      debugPrint('Moved ${b.path}, but could not update the library: $e');
    }
  }
  final parts = [
    if (moved > 0) '${comicsCount(moved)} moved to ${p.basename(dir)}',
    if (skipped > 0) '${comicsCount(skipped)} left where ${skipped == 1 ? 'it was' : 'they were'}',
    if (failed.isNotEmpty) 'could not move ${failed.first}${failed.length > 1 ? ' and ${failed.length - 1} more' : ''}',
  ];
  messenger.showSnackBar(SnackBar(content: Text(parts.isEmpty ? 'Nothing moved' : parts.join('; '))));
  return true;
}

/// Asks what to do when [names] are taken in [dir]: replace what is there
/// (deleted for good, as a delete would), skip those, or cancel. Cancel has
/// the focus, so Enter or Esc changes nothing.
Future<MoveClash> askMoveClash(BuildContext context, List<String> names, String dir) async =>
    await showDialog<MoveClash>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        const shown = 6;
        final one = names.length == 1;
        return DialogHotkeys(
          child: AlertDialog(
            key: const Key('moveClashDialog'),
            title: Text(one ? '${names.single} is in ${p.basename(dir)} already' : '${names.length} names are taken'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!one) ...[
                    Text('In ${p.basename(dir)} there are already:', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final n in names.take(shown)) Text(n, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (names.length > shown)
                      Text('and ${names.length - shown} more', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    'Replace deletes ${one ? 'the one' : 'those'} in ${p.basename(dir)} for good, with '
                    '${one ? 'its' : 'their'} sidecars, and moves yours in. Skip leaves '
                    '${one ? 'yours where it is' : 'yours of those names where they are and moves the rest'}.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const Key('moveClashCancel'),
                autofocus: true,
                onPressed: () => Navigator.pop(context, MoveClash.cancel),
                child: const Mnemonic('Cancel'),
              ),
              OutlinedButton(
                key: const Key('moveClashSkip'),
                onPressed: () => Navigator.pop(context, MoveClash.skip),
                child: Mnemonic(one ? 'Skip it' : 'Skip those'),
              ),
              FilledButton(
                key: const Key('moveClashReplace'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, MoveClash.replace),
                child: const Mnemonic('Replace'),
              ),
            ],
          ),
        );
      },
    ) ??
    MoveClash.cancel;

/// The folder picker for a move: type to narrow the list, `↑` `↓` to pick,
/// Enter to move there; New folder (`Ctrl+N`) makes one in the picked
/// folder and moves there. Pops with the folder's path.
class MoveDialog extends StatefulWidget {
  const MoveDialog({super.key, required this.what, required this.targets, this.current});

  /// The comic's name, or how many comics.
  final String what;
  final List<MoveTarget> targets;

  /// The folder picked first: the one the Folders tab shows.
  final String? current;

  @override
  State<MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<MoveDialog> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  static const _rowHeight = 40.0;
  late List<MoveTarget> _shown = widget.targets;
  int _at = 0;

  @override
  void initState() {
    super.initState();
    final i = widget.current == null ? -1 : widget.targets.indexWhere((t) => p.equals(t.path, widget.current!));
    if (i >= 0) {
      _at = i;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  MoveTarget? get _picked => _shown.isEmpty ? null : _shown[_at.clamp(0, _shown.length - 1)];

  void _filter(String query) => setState(() {
    final was = _picked;
    _shown = widget.targets.where((t) => matchesTarget(t, query)).toList();
    final i = was == null ? -1 : _shown.indexOf(was);
    _at = i >= 0 ? i : 0;
  });

  void _step(int by) {
    if (_shown.isEmpty) return;
    setState(() => _at = (_at + by).clamp(0, _shown.length - 1));
    _reveal();
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _at * _rowHeight, view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  void _move() {
    if (_picked case final t?) Navigator.pop(context, t.path);
  }

  Future<void> _newFolder() async {
    final parent = _picked;
    if (parent == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NewFolderDialog(parent: parent),
    );
    if (name == null || !mounted) return;
    final dir = p.join(parent.path, name);
    try {
      await Directory(dir).create();
    } on FileSystemException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make $name: ${e.message}')));
      return;
    }
    if (mounted) Navigator.pop(context, dir);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = _picked;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(8),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-8),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newFolder,
      },
      child: DialogHotkeys(
        child: AlertDialog(
          key: const Key('moveDialog'),
          title: Text('Move ${widget.what} to'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('moveFilter'),
                  controller: _field,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Type to find a folder, ↑ ↓ to pick, Enter to move',
                  ),
                  onChanged: _filter,
                  onSubmitted: (_) => _move(),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: _rowHeight * 8,
                  child: _shown.isEmpty
                      ? Center(child: Text('No folder matches', style: theme.textTheme.bodyMedium))
                      : ListView.builder(
                          key: const Key('moveTargets'),
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          itemCount: _shown.length,
                          itemBuilder: (context, i) => ListTile(
                            key: Key('moveTarget-${_shown[i].label}'),
                            dense: true,
                            selected: i == _at,
                            selectedTileColor: theme.colorScheme.secondaryContainer,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(_shown[i].label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => setState(() => _at = i),
                          ),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              key: const Key('moveNewFolder'),
              onPressed: picked == null ? null : _newFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Mnemonic('New folder (Ctrl+N)'),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Mnemonic('Cancel')),
            FilledButton(
              key: const Key('moveHere'),
              onPressed: picked == null ? null : _move,
              child: Mnemonic(picked == null ? 'Move' : 'Move to ${p.basename(picked.path)}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for the name of a new folder in [parent].
class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({required this.parent});

  final MoveTarget parent;

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() {
    final name = _field.text.trim();
    final error = switch (name) {
      '' => 'Give it a name',
      '.' || '..' => 'Not a name a folder can have',
      _ when name.contains('/') || name.contains(r'\') => 'A name without / in it',
      _ when name.startsWith('.') => 'The library skips folders starting with a dot',
      _ => null,
    };
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => DialogHotkeys(
    child: AlertDialog(
      key: const Key('newFolderDialog'),
      title: Text('New folder in ${widget.parent.label}'),
      content: SizedBox(
        width: 400,
        child: TextField(
          key: const Key('newFolderName'),
          controller: _field,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Name', errorText: _error),
          onSubmitted: (_) => _done(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Mnemonic('Cancel')),
        FilledButton(
          key: const Key('newFolderMake'),
          onPressed: _done,
          child: const Mnemonic('Make it and move there'),
        ),
      ],
    ),
  );
}
