import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/s3_sync.dart';
import '../hotkeys.dart';
import '../reader/reader_notifier.dart';
import '../undo_notice.dart';
import 'delete_book.dart';
import 'library_store.dart';

/// The library's S3 actions (design plan section 13), for `gu`, `gU`, the
/// marked-books bar and the book's details. Each says in a notice what it
/// did, or why it did nothing.

bool _setUp(BuildContext context, WidgetRef ref) {
  if (ref.read(s3SyncProvider).current.on) return true;
  showNotice(ScaffoldMessenger.of(context), 'Set up S3 sync first: Settings → S3 sync');
  return false;
}

/// Uploads [books] in the background. One already in the bucket (the same
/// content key and size) is not sent again; its sidecar and the bucket's
/// are brought in step instead, the newest winning.
Future<void> uploadBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  if (!_setUp(context, ref)) return;
  final messenger = ScaffoldMessenger.of(context);
  final todo = books.where((b) => !b.remoteOnly).toList();
  if (todo.isEmpty) {
    showNotice(messenger, books.length == 1 ? '${books.first.name} is on S3 only' : 'These are on S3 only');
    return;
  }
  final n = await ref.read(s3SyncProvider).upload(todo.map((b) => b.key));
  if (n == 0) {
    showNotice(messenger, 'On its way to S3 already');
    return;
  }
  final synced = todo.every((b) => b.s3 != null);
  showNotice(messenger, switch ((n, synced)) {
    (1, true) => 'Bringing ${todo.first.name} in step with S3',
    (_, true) => 'Bringing $n comics in step with S3',
    (1, false) => 'Uploading ${todo.first.name} to S3',
    _ => 'Uploading $n comics to S3',
  });
}

/// Downloads [books] that are on S3 only, one after the other.
Future<void> downloadBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  if (!_setUp(context, ref)) return;
  final todo = books.where((b) => b.remoteOnly).toList();
  if (todo.isEmpty) return;
  final s3 = ref.read(s3SyncProvider);
  showNotice(
    ScaffoldMessenger.of(context),
    todo.length == 1
        ? 'Downloading ${todo.first.name} (${describeBytes(todo.first.s3?.size ?? 0)})'
        : 'Downloading ${todo.length} comics',
  );
  for (final b in todo) {
    await s3.download(b.key);
  }
}

/// Takes [books] off S3 after asking; nothing on this device changes.
/// False when nothing was taken off: none on S3, or cancelled.
Future<bool> removeBooksFromS3(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final todo = books.where((b) => b.s3 != null).toList();
  if (todo.isEmpty) {
    showNotice(
      ScaffoldMessenger.of(context),
      books.length == 1 ? '${books.first.name} is not on S3' : 'None of these is on S3',
    );
    return false;
  }
  final what = todo.length == 1 ? todo.first.name : '${todo.length} comics';
  final local = todo.where((b) => !b.remoteOnly).length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => DialogHotkeys(
      child: AlertDialog(
        key: const Key('s3RemoveDialog'),
        icon: const Icon(Icons.cloud_off),
        title: Text('Remove $what from S3?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(
            [
              'The copy in the bucket and its sidecar there are deleted.',
              if (local > 0) 'The comic and its sidecar on this device stay.',
              if (local < todo.length) 'A comic that is only on S3 disappears from this library.',
              "The other device keeps its own copy, if it downloaded one.",
            ].join(' '),
          ),
        ),
        actions: _removeButtons(context),
      ),
    ),
  );
  if (ok != true) return false;
  unawaited(ref.read(s3SyncProvider).removeFromS3(todo.map((b) => b.key)));
  return true;
}

/// Cancel (Alt+C, and Enter: something would be lost) and Remove from S3
/// (Alt+R).
List<Widget> _removeButtons(BuildContext context) => [
  TextButton(
    key: const Key('s3RemoveCancel'),
    autofocus: true,
    onPressed: () => Navigator.pop(context, false),
    child: const Mnemonic('Cancel'),
  ),
  FilledButton.icon(
    key: const Key('s3RemoveConfirm'),
    onPressed: () => Navigator.pop(context, true),
    icon: const Icon(Icons.cloud_off),
    label: const Mnemonic('Remove from S3'),
  ),
];

/// "On S3 since 26 Sep, uploaded from ThinkPad", for the details.
String describeShelf(LibraryBook book, S3Status status) {
  final shelf = book.s3;
  if (shelf == null) return 'Not on S3';
  final at = shelf.uploadedAt;
  final since = at == null ? '' : ' since ${at.day} ${_months[at.month - 1]} ${at.year}';
  final from = (shelf.uploadedBy ?? '').isEmpty ? '' : ', uploaded from ${shelf.uploadedBy}';
  final state = switch (shelf.mark) {
    _ when status.reach == S3Reach.unreachable && shelf.mark != S3Mark.remote =>
      '; the bucket is out of reach, so changes are saved here and go up later',
    S3Mark.waiting => '; changes waiting to go up',
    S3Mark.remote => '; not downloaded to this device',
    S3Mark.synced => '',
  };
  return 'On S3$since$from$state';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
