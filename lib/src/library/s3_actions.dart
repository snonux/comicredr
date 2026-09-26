import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/s3_sync.dart';
import '../reader/reader_notifier.dart';
import 'delete_book.dart';
import 'library_store.dart';

/// The library's S3 actions (design plan section 13), for `gu`, `gU`, the
/// marked-books bar and the book's details. Each says in a notice what it
/// did, or why it did nothing.

bool _setUp(BuildContext context, WidgetRef ref) {
  if (ref.read(s3SyncProvider).current.on) return true;
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Set up S3 sync first: Settings → S3 sync')));
  return false;
}

/// Uploads [books] that are not on S3 yet, in the background.
Future<void> uploadBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  if (!_setUp(context, ref)) return;
  final messenger = ScaffoldMessenger.of(context);
  final todo = books.where((b) => b.s3 == null).toList();
  if (todo.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text(books.length == 1 ? '${books.first.name} is on S3 already' : 'These are on S3 already')),
    );
    return;
  }
  final n = await ref.read(s3SyncProvider).upload(todo.map((b) => b.key));
  messenger.showSnackBar(
    SnackBar(content: Text(n == 1 ? 'Uploading ${todo.first.name} to S3' : 'Uploading $n comics to S3')),
  );
}

/// Downloads [books] that are on S3 only, one after the other.
Future<void> downloadBooks(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  if (!_setUp(context, ref)) return;
  final todo = books.where((b) => b.remoteOnly).toList();
  if (todo.isEmpty) return;
  final s3 = ref.read(s3SyncProvider);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        todo.length == 1
            ? 'Downloading ${todo.first.name} (${describeBytes(todo.first.s3?.size ?? 0)})'
            : 'Downloading ${todo.length} comics',
      ),
    ),
  );
  for (final b in todo) {
    await s3.download(b.key);
  }
}

/// Takes [books] off S3 after asking; nothing on this device changes.
Future<void> removeBooksFromS3(BuildContext context, WidgetRef ref, List<LibraryBook> books) async {
  final todo = books.where((b) => b.s3 != null).toList();
  if (todo.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(books.length == 1 ? '${books.first.name} is not on S3' : 'None of these is on S3')),
    );
    return;
  }
  final what = todo.length == 1 ? todo.first.name : '${todo.length} comics';
  final local = todo.where((b) => !b.remoteOnly).length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
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
      actions: [
        TextButton(
          key: const Key('s3RemoveCancel'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('s3RemoveConfirm'),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.cloud_off),
          label: const Text('Remove from S3'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  unawaited(ref.read(s3SyncProvider).removeFromS3(todo.map((b) => b.key)));
}

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
