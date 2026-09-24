import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import '../providers.dart';
import '../reader/reader_notifier.dart';
import '../version.dart';
import 'providers.dart';

/// The settings (M8): what the reader and the sidecars do by default, which
/// panel detector is in use, and the reading history. A dialog, so `Esc`
/// closes it on the laptop and it fits a phone.
Future<void> showSettings(BuildContext context, {VoidCallback? onExportSidecars}) => showDialog<void>(
  context: context,
  builder: (_) => SettingsDialog(onExportSidecars: onExportSidecars),
);

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key, this.onExportSidecars});

  final VoidCallback? onExportSidecars;

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  bool? _wholePage;
  bool? _sidecars;
  bool? _detectLibrary;
  String? _detector;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final whole = await settings.loadBool(SettingsStore.wholePageSteps);
    final sidecars = await settings.loadBool(SettingsStore.writeSidecars);
    final detectLibrary = await settings.loadBool(SettingsStore.detectLibrary);
    final detector = await ref.read(panelDetectorProvider.future);
    if (!mounted) return;
    setState(() {
      _wholePage = whole ?? true;
      _sidecars = sidecars ?? true;
      _detectLibrary = detectLibrary ?? detectLibraryByDefault;
      _detector = detector.model == null
          ? 'Classic computer vision. Install the trained model for balloons and better panels (see the README).'
          : 'The trained model: ${detector.model!.path}';
    });
  }

  Future<void> _set(String key, bool value) async {
    await ref.read(settingsStoreProvider).saveBool(key, value);
    if (key == SettingsStore.detectLibrary) await ref.read(libraryDetectionProvider).reload();
    await _load();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear reading history?'),
        content: const Text('Your positions, bookmarks and collections stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    final db = ref.read(databaseProvider);
    await db.delete(db.readLog).go();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reading history cleared')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 520,
        child: _wholePage == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading('Guided view'),
                    SwitchListTile(
                      key: const Key('setting-wholePage'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show each page whole before and after its panels'),
                      subtitle: const Text('w switches it while reading'),
                      value: _wholePage!,
                      onChanged: (v) => _set(SettingsStore.wholePageSteps, v),
                    ),
                    Text('Panel detector', style: theme.textTheme.bodyMedium),
                    Text(_detector ?? '', key: const Key('setting-detector'), style: theme.textTheme.bodySmall),
                    SwitchListTile(
                      key: const Key('setting-detectLibrary'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Find the panels of the whole library in the background'),
                      subtitle: const Text(
                        'So guided view is ready in any book. It waits while you read, and the status line can pause it.',
                      ),
                      value: _detectLibrary!,
                      onChanged: (v) => _set(SettingsStore.detectLibrary, v),
                    ),
                    heading('Sidecars'),
                    SwitchListTile(
                      key: const Key('setting-sidecars'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Save panels, bookmarks and position in a file beside each comic'),
                      subtitle: const Text(
                        'So they travel when you copy the comic. Sidecars already there are always read.',
                      ),
                      value: _sidecars!,
                      onChanged: (v) => _set(SettingsStore.writeSidecars, v),
                    ),
                    if (widget.onExportSidecars case final export?)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          key: const Key('setting-export'),
                          onPressed: () {
                            Navigator.pop(context);
                            export();
                          },
                          icon: const Icon(Icons.drive_file_move_outline),
                          label: const Text('Export sidecars to a folder…'),
                        ),
                      ),
                    heading('Reading history'),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('setting-clearHistory'),
                        onPressed: _clearHistory,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('Clear reading history'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('ComicRedr $appVersion', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const Key('setting-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
