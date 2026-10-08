import 'package:flutter/material.dart';

import '../hotkeys.dart';

/// What a reset of one comic throws away (see SidecarSync.reset).
enum ResetScope {
  /// Detected panels and balloons only; they are found again.
  panels,

  /// Panels, bookmarks and marks, positions, the completed mark, reading
  /// history and metadata edits: the comic starts from scratch. Collections
  /// keep it.
  everything,
}

/// Asks before resetting the comic [title]: `X` in the reader or the
/// library, or the button in the book's details. With a [count] above one,
/// [title] is what the marked comics are called ("5 comics"). Null when
/// cancelled.
Future<ResetScope?> askReset(BuildContext context, String title, {int count = 1}) => showDialog<ResetScope>(
  context: context,
  builder: (context) => DialogHotkeys(
    child: AlertDialog(
      key: const Key('resetDialog'),
      title: Text('Reset $title?'),
      content: Text(
        count == 1
            ? 'Redo panels forgets the panels and balloons found in this comic and finds them again.\n\n'
                  'Reset everything also forgets its bookmarks and marks, where you are in it on every device, '
                  'that it is completed and its reading history, here and in the file beside the comic. '
                  'Its collections stay.'
            : 'Redo panels forgets the panels and balloons found in each of these comics and finds them again.\n\n'
                  'Reset everything also forgets their bookmarks and marks, where you are in each on every device, '
                  'that they are completed and their reading history, here and in the files beside the comics. '
                  'Their collections stay.',
      ),
      actions: [
        TextButton(
          key: const Key('resetCancel'),
          onPressed: () => Navigator.pop(context),
          child: const Mnemonic('Cancel'),
        ),
        TextButton(
          key: const Key('resetPanels'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, ResetScope.panels),
          child: const Mnemonic('Redo panels', letter: 'p'),
        ),
        FilledButton(
          key: const Key('resetEverything'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, ResetScope.everything),
          child: const Mnemonic('Reset everything'),
        ),
      ],
    ),
  ),
);
