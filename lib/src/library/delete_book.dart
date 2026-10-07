import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/book_paths.dart';
import '../data/sidecar_sync.dart';
import '../hotkeys.dart';
import 'library_store.dart';

/// What the delete dialog says about a comic before it goes.
class DeleteFacts {
  const DeleteFacts({
    required this.name,
    required this.path,
    required this.folder,
    required this.bytes,
    required this.pages,
    this.link = false,
    this.onS3 = false,
  });

  final String name;
  final String path;

  /// A folder of page images: the whole folder goes.
  final bool folder;
  final int bytes;
  final int pages;

  /// A symlink in the library: only the link goes, never what it points to.
  final bool link;

  /// On the S3 shelf: the dialog asks whether the bucket's copy goes too.
  final bool onS3;

  DeleteFacts withS3(bool onS3) =>
      DeleteFacts(name: name, path: path, folder: folder, bytes: bytes, pages: pages, link: link, onS3: onS3);
}

/// What the delete dialog was answered with.
enum DeleteChoice {
  cancel,

  /// The comic here; a copy on S3 stays there.
  here,

  /// The comic here and its copy on S3 (design plan section 13).
  everywhere,
}

/// Gathers what [askDelete] shows about the book at [path].
Future<DeleteFacts> deleteFacts(String name, String path, {required bool folder, required int pages}) async {
  var bytes = 0;
  try {
    if (folder) {
      await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
        if (e is File) bytes += await e.length();
      }
    } else {
      bytes = await File(path).length();
    }
  } on FileSystemException {
    // The dialog shows no size rather than failing.
  }
  final link = await FileSystemEntity.isLink(path);
  return DeleteFacts(name: name, path: path, folder: folder, bytes: bytes, pages: pages, link: link);
}

/// `1.2 MB`, `830 KB`.
String describeBytes(int bytes) {
  if (bytes >= 1000 * 1000 * 1000) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1000 * 1000) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).round()} KB';
  return '$bytes bytes';
}

/// Asks before deleting a comic: `gd` or Shift+Delete in the reader or on
/// a selected cover, or the button in the book's details. Cancel has the
/// focus, so Enter or Esc never deletes by accident. A comic on S3 gets
/// two ways to delete: only here, or here and from S3; the other device's
/// own copy is never touched.
Future<DeleteChoice> askDelete(BuildContext context, DeleteFacts f) async =>
    await showDialog<DeleteChoice>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final what = f.folder
            ? 'The folder ${p.basename(f.path)} (${f.pages} ${f.pages == 1 ? 'page' : 'pages'}, ${describeBytes(f.bytes)})'
            : '${p.basename(f.path)} (${describeBytes(f.bytes)})';
        return DialogHotkeys(
          child: AlertDialog(
            key: const Key('deleteDialog'),
            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            title: Text('Delete ${f.name}?'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(what, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SelectableText(p.dirname(f.path), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 16),
                  Text(
                    f.link
                        ? 'It is a link: the link is deleted with its sidecar, its bookmarks, position and panels. '
                              'The comic it points to stays where it is.'
                        : 'It is deleted for good with its sidecar, its bookmarks, position and panels. '
                              'It does not go to the trash, so it cannot be restored.',
                  ),
                  if (f.onS3) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'It is on S3 too. Delete only here keeps the copy in the bucket, and the comic stays in the '
                      'library to download again; the other device keeps its own copy either way.',
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const Key('deleteCancel'),
                autofocus: true,
                onPressed: () => Navigator.pop(context, DeleteChoice.cancel),
                child: const Mnemonic('Cancel'),
              ),
              if (f.onS3)
                OutlinedButton.icon(
                  key: const Key('deleteHere'),
                  style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: () => Navigator.pop(context, DeleteChoice.here),
                  icon: const Icon(Icons.delete_outline),
                  label: const Mnemonic('Delete only here', letter: 'o'),
                ),
              FilledButton.icon(
                key: Key(f.onS3 ? 'deleteEverywhere' : 'deleteConfirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, f.onS3 ? DeleteChoice.everywhere : DeleteChoice.here),
                icon: Icon(f.onS3 ? Icons.cloud_off : Icons.delete_outline),
                label: Mnemonic(
                  f.onS3
                      ? 'Delete here and from S3'
                      : f.link
                      ? 'Delete the link'
                      : 'Delete for good',
                ),
              ),
            ],
          ),
        );
      },
    ) ??
    DeleteChoice.cancel;

/// Asks once before deleting several marked comics (`gd`, Shift+Delete or
/// Delete in the marks bar): their names, how much they take, and, when
/// any is on S3, the same three choices as for one. [remoteOnly] counts
/// marked comics that are only on S3: only "Delete here and from S3" does
/// anything to them. Cancel has the focus.
Future<DeleteChoice> askDeleteMany(BuildContext context, List<DeleteFacts> facts, {int remoteOnly = 0}) async =>
    await showDialog<DeleteChoice>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final onS3 = remoteOnly > 0 || facts.any((f) => f.onS3);
        final links = facts.where((f) => f.link).length;
        final bytes = facts.fold<int>(0, (sum, f) => sum + f.bytes);
        final n = facts.length + remoteOnly;
        const shown = 8;
        return DialogHotkeys(
          child: AlertDialog(
            key: const Key('deleteDialog'),
            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            title: Text('Delete $n comics?'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (facts.isNotEmpty)
                    Text(
                      '${facts.length} on this device, ${describeBytes(bytes)} together',
                      key: const Key('deleteManyTotal'),
                      style: theme.textTheme.titleSmall,
                    ),
                  const SizedBox(height: 4),
                  for (final f in facts.take(shown))
                    Text('${f.name}  ·  ${p.basename(f.path)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (facts.length > shown) Text('and ${facts.length - shown} more', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 16),
                  if (facts.isNotEmpty)
                    Text(
                      'They are deleted for good with their sidecars, bookmarks, positions and panels. '
                      'They do not go to the trash, so they cannot be restored.'
                      '${links == 0 ? '' : ' Of ${_theLinks(links)}, only the link goes.'}',
                    ),
                  if (onS3) ...[
                    const SizedBox(height: 12),
                    Text(
                      [
                        if (facts.any((f) => f.onS3))
                          'Some are on S3 too. Delete only here keeps their copies in the bucket, and they stay in the '
                              'library to download again.',
                        if (remoteOnly > 0)
                          '$remoteOnly ${remoteOnly == 1 ? 'is' : 'are'} only on S3: only Delete here and from S3 '
                              'takes ${remoteOnly == 1 ? 'it' : 'them'} away.',
                        'The other device keeps its own copies either way.',
                      ].join(' '),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const Key('deleteCancel'),
                autofocus: true,
                onPressed: () => Navigator.pop(context, DeleteChoice.cancel),
                child: const Mnemonic('Cancel'),
              ),
              if (onS3 && facts.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('deleteHere'),
                  style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: () => Navigator.pop(context, DeleteChoice.here),
                  icon: const Icon(Icons.delete_outline),
                  label: const Mnemonic('Delete only here', letter: 'o'),
                ),
              FilledButton.icon(
                key: Key(onS3 ? 'deleteEverywhere' : 'deleteConfirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, onS3 ? DeleteChoice.everywhere : DeleteChoice.here),
                icon: Icon(onS3 ? Icons.cloud_off : Icons.delete_outline),
                label: Mnemonic(onS3 ? 'Delete here and from S3' : 'Delete $n for good'),
              ),
            ],
          ),
        );
      },
    ) ??
    DeleteChoice.cancel;

/// Deletes [path] for good, a file or a whole folder. Throws a
/// [FileSystemException] when it can't.
Future<void> removePath(String path) async {
  if (await FileSystemEntity.isLink(path)) {
    await Link(path).delete(); // The link only; what it points to stays.
  } else if (await FileSystemEntity.isDirectory(path)) {
    await Directory(path).delete(recursive: true);
  } else {
    await File(path).delete();
  }
}

/// Deletes the comic at [path] for good (not to the trash): the file or folder, every sidecar of it
/// ([SidecarSync.forget]), its row in the index, and when it was the last
/// copy everything else kept about it, its cover and its page thumbnails.
/// The comic goes first: if that fails nothing else is touched. Returns
/// the sidecars that could not be removed, normally none.
///
/// Close the book in the reader first, so nothing writes to it meanwhile.
Future<List<String>> deleteComic({
  required String path,
  required String contentKey,
  required bool folder,
  required SidecarSync sidecars,
  required LibraryStore store,
  required String coverDir,
  bool keepCover = false,
}) async {
  final places = await sidecars.forget(path, contentKey, folder: folder);
  await removePath(path);
  final stuck = <String>[];
  for (final s in places) {
    // A folder book's own sidecar went with the folder.
    if (FileSystemEntity.typeSync(s) == FileSystemEntityType.notFound) continue;
    try {
      await removePath(s);
    } on FileSystemException catch (e) {
      debugPrint('Could not delete the sidecar $s: $e');
      stuck.add(s);
    }
  }
  final last = await store.forgetDeleted(path, contentKey);
  if (last) {
    try {
      final cover = File(coverFile(coverDir, contentKey));
      // A comic still on S3 keeps its cover for the library's cloud entry.
      if (!keepCover && await cover.exists()) await cover.delete();
      final pages = Directory(pageThumbDir(coverDir, contentKey));
      if (await pages.exists()) await pages.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Could not delete the cached pictures of $path: $e');
    }
  }
  return stuck;
}

/// The notice after a delete.
String deletedNotice(String name, List<String> stuck) =>
    stuck.isEmpty ? '$name deleted' : '$name deleted, but its sidecar ${stuck.first} could not be removed';

/// The [links] among the comics to delete, as the question names them.
String _theLinks(int links) => links == 1 ? 'the one that is a link' : 'the $links that are links';
