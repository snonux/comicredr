import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hotkeys.dart';

/// Explains the device's storage permission before the native request.
/// A request returns false: retry the original action after Android grants
/// access. Private app data never goes through this shared-storage gate.
Future<bool> hasAndroidStorageAccess(BuildContext context, MethodChannel storage) async {
  final granted = await storage.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  if (!context.mounted) return false;
  if (granted) return true;
  final allFiles = await storage.invokeMethod<bool>('usesAllFilesAccess') ?? false;
  if (!context.mounted) return false;
  final instructions = allFiles
      ? 'Android asks for that as "All files access", on a settings page. '
            'Turn it on there, then come back and try again.'
      : 'Allow the Storage permission in the Android dialog, then try again. '
            'If Android no longer asks, enable Storage in Settings → Apps → ComicRedr → Permissions.';
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => DialogHotkeys(
      child: AlertDialog(
        title: const Text('Allow access to your comics'),
        content: Text(
          'ComicRedr reads comics where they are in the device\'s storage. '
          '$instructions',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Mnemonic('Not now')),
          // The default: Enter goes on to Android's own page or question.
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: Mnemonic(allFiles ? 'Open settings' : 'Allow access'),
          ),
        ],
      ),
    ),
  );
  if (go == true) await storage.invokeMethod<void>('requestAllFilesAccess');
  return false;
}
