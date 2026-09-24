import 'package:flutter/material.dart';

/// What a reset of one comic throws away (see SidecarSync.reset).
enum ResetScope {
  /// Detected panels and balloons only; they are found again.
  panels,

  /// Panels, bookmarks and marks, positions, reading history and metadata
  /// edits: the comic starts from scratch. Collections keep it.
  everything,
}

/// Asks before resetting the comic [title]: `X` in the reader or the
/// library, or the button in the book's details. Null when cancelled.
Future<ResetScope?> askReset(BuildContext context, String title) => showDialog<ResetScope>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('resetDialog'),
    title: Text('Reset $title?'),
    content: const Text(
      'Redo panels forgets the panels and balloons found in this comic and finds them again.\n\n'
      'Reset everything also forgets its bookmarks and marks, where you are in it on every device, '
      'and its reading history, here and in the file beside the comic. Its collections stay.',
    ),
    actions: [
      TextButton(key: const Key('resetCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        key: const Key('resetPanels'),
        autofocus: true,
        onPressed: () => Navigator.pop(context, ResetScope.panels),
        child: const Text('Redo panels'),
      ),
      FilledButton(
        key: const Key('resetEverything'),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        onPressed: () => Navigator.pop(context, ResetScope.everything),
        child: const Text('Reset everything'),
      ),
    ],
  ),
);
