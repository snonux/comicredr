import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reader_input/reader_input.dart';

import '../data/settings_store.dart';
import '../input/touch_providers.dart';
import '../input/touch_zones.dart';
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
  bool? _pauseWhole;
  PauseCue? _pauseCue;
  bool? _cleanUp;
  bool? _sidecars;
  bool? _detectLibrary;
  String? _sidecarDir;
  bool _moving = false;
  String? _detector;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final whole = await settings.loadBool(SettingsStore.wholePageSteps);
    final pause = await settings.loadBool(SettingsStore.pauseWhole);
    final cue = await settings.loadString(SettingsStore.pauseCue);
    final cleanUp = await settings.loadBool(SettingsStore.cleanUp);
    final sidecars = await settings.loadBool(SettingsStore.writeSidecars);
    final detectLibrary = await settings.loadBool(SettingsStore.detectLibrary);
    final sidecarDir = await settings.loadString(SettingsStore.sidecarDir);
    final detector = await ref.read(panelDetectorProvider.future);
    if (!mounted) return;
    setState(() {
      _wholePage = whole ?? true;
      _pauseWhole = pause ?? true;
      _pauseCue = PauseCue.values.asNameMap()[cue] ?? PauseCue.colour;
      _cleanUp = cleanUp ?? false;
      _sidecars = sidecars ?? true;
      _detectLibrary = detectLibrary ?? detectLibraryByDefault;
      _sidecarDir = sidecarDir;
      _detector = detector.model == null
          ? 'Classic computer vision. Build with the trained model for balloons and better panels (see "The panel detector" in the guide).'
          : 'The trained model: ${detector.model!.path}';
    });
  }

  Future<void> _set(String key, bool value) async {
    await ref.read(settingsStoreProvider).saveBool(key, value);
    if (key == SettingsStore.detectLibrary) await ref.read(libraryDetectionProvider).reload();
    await _load();
  }

  /// Asks for the folder to keep sidecars in: the system's folder picker
  /// on the laptop, a path on the phone, which has none that gives one.
  Future<String?> _pickFolder() async {
    if (!Platform.isAndroid) return getDirectoryPath(confirmButtonText: 'Keep comic data here');
    final field = TextEditingController(text: _sidecarDir ?? '/storage/emulated/0/ComicRedr');
    final dir = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep comic data in'),
        content: TextField(
          key: const Key('sidecarDir-field'),
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: const Text('Use')),
        ],
      ),
    );
    field.dispose();
    return dir;
  }

  /// Keeps sidecars in [dir] from now on, or beside each comic when null,
  /// and offers to move the ones already written; nothing moves unasked.
  Future<void> _setSidecarDir(String? dir) async {
    final old = _sidecarDir;
    if (dir == old || _moving) return;
    final sync = ref.read(sidecarSyncProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _moving = true);
    try {
      final n = await sync.countIn(old);
      await ref.read(settingsStoreProvider).saveString(SettingsStore.sidecarDir, dir);
      sync.placeChanged();
      await _load();
      if (n == 0 || !mounted) return;
      final files = '$n comic data file${n == 1 ? '' : 's'}';
      final move = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Move $files?'),
          content: Text(
            '${old == null ? 'They are beside your comics' : 'They are in $old'}. '
            'Move them ${dir == null ? 'beside each comic' : 'to $dir'}? '
            'Files you leave are still read.',
          ),
          actions: [
            TextButton(
              key: const Key('sidecarMove-leave'),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Leave them'),
            ),
            FilledButton(
              key: const Key('sidecarMove-move'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Move'),
            ),
          ],
        ),
      );
      if (move != true) return;
      final moved = await sync.moveAll(from: old, to: dir);
      messenger.showSnackBar(
        SnackBar(content: Text('Moved $moved of $files${moved < n ? '; the rest could not be moved' : ''}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not change where comic data is kept: $e')));
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  Future<void> _chooseSidecarDir() async {
    final dir = await _pickFolder();
    if (dir == null || dir.isEmpty) return;
    await _setSidecarDir(dir);
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
                    heading('Pages'),
                    SwitchListTile(
                      key: const Key('setting-cleanUp'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Clean up old scans'),
                      subtitle: const Text(
                        'Whitens yellowed paper, darkens faded ink, and enlarges and sharpens pages smaller than the '
                        'screen. c switches it while reading.',
                      ),
                      value: _cleanUp!,
                      onChanged: (v) => _set(SettingsStore.cleanUp, v),
                    ),
                    heading('Guided view'),
                    SwitchListTile(
                      key: const Key('setting-wholePage'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show each page whole before and after its panels'),
                      subtitle: const Text('w switches it while reading'),
                      value: _wholePage!,
                      onChanged: (v) => _set(SettingsStore.wholePageSteps, v),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On a page without panels, the first step stays'),
                      subtitle: const Text(
                        'and shows it: the background turns wine red, or the page zooms out and back. The next step '
                        'turns. W switches it off and on while reading, gw picks the cue.',
                      ),
                    ),
                    SegmentedButton<PauseCue?>(
                      key: const Key('setting-pauseCue'),
                      showSelectedIcon: _roomForTicks(context),
                      segments: const [
                        ButtonSegment(value: null, label: Text('Off')),
                        ButtonSegment(value: PauseCue.colour, label: Text('Colour')),
                        ButtonSegment(value: PauseCue.zoom, label: Text('Zoom')),
                      ],
                      selected: {_pauseWhole! ? _pauseCue : null},
                      onSelectionChanged: (v) async {
                        final cue = v.first;
                        await ref.read(settingsStoreProvider).saveBool(SettingsStore.pauseWhole, cue != null);
                        if (cue != null) {
                          await ref.read(settingsStoreProvider).saveString(SettingsStore.pauseCue, cue.name);
                        }
                        await _load();
                      },
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
                      title: const Text('Save panels, bookmarks and position in a file for each comic'),
                      subtitle: const Text('Hidden files, like .book.cbz.crdb. Sidecars already there are always read.'),
                      value: _sidecars!,
                      onChanged: (v) => _set(SettingsStore.writeSidecars, v),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: SegmentedButton<bool>(
                        key: const Key('setting-sidecarPlace'),
                        showSelectedIcon: _roomForTicks(context),
                        segments: const [
                          ButtonSegment(value: false, label: Text('Beside each comic')),
                          ButtonSegment(value: true, label: Text('In one folder')),
                        ],
                        selected: {_sidecarDir != null},
                        onSelectionChanged: _moving
                            ? null
                            : (v) => v.first ? _chooseSidecarDir() : _setSidecarDir(null),
                      ),
                    ),
                    if (_sidecarDir case final dir?)
                      Row(
                        children: [
                          Expanded(
                            child: Text(dir, key: const Key('setting-sidecarDir'), style: theme.textTheme.bodySmall),
                          ),
                          TextButton(
                            key: const Key('setting-sidecarDir-change'),
                            onPressed: _moving ? null : _chooseSidecarDir,
                            child: const Text('Change…'),
                          ),
                        ],
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 6),
                        child: Text('So they travel when you copy the comic.', style: theme.textTheme.bodySmall),
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
                    heading('Touch'),
                    _TouchPicker(),
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

/// Picks the touch preset, with a small drawing of its tap zones. Lines in
/// `keys.toml`'s `[touch]` section still apply on top.
class _TouchPicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final preset = ref.watch(touchPresetProvider);
    final changed = ref.watch(keymapLoadProvider).load.touch.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<TouchPreset>(
          key: const Key('setting-touch'),
          showSelectedIcon: _roomForTicks(context),
          segments: [
            for (final p in TouchPreset.values)
              ButtonSegment(
                value: p,
                label: Text(p.label, key: Key('setting-touch-${p.name}')),
              ),
          ],
          selected: {preset},
          onSelectionChanged: (s) => ref.read(touchPresetProvider.notifier).pick(s.single),
        ),
        const SizedBox(height: 8),
        Text(preset.description, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: SizedBox(
            key: const Key('setting-touch-preview'),
            width: 240,
            height: 150,
            child: TouchZonesView(map: ref.watch(touchMapProvider), compact: true),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          [
            'Double-tap the middle to zoom, swipe to turn, gt shows the zones while reading.',
            if (changed > 0) 'keys.toml changes $changed ${changed == 1 ? 'gesture' : 'gestures'} on top of this.',
          ].join(' '),
          key: const Key('setting-touch-note'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Whether a segmented button has room for the tick on its picked segment.
/// On a phone the tick squeezed labels until they broke mid-word ("Colou r",
/// "Stand ard"); the picked segment stays filled without it.
bool _roomForTicks(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;
