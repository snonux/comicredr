import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reader_input/reader_input.dart';

import '../data/s3_settings.dart';
import '../data/settings_store.dart';
import '../hotkeys.dart';
import '../input/touch_providers.dart';
import '../input/touch_zones.dart';
import '../providers.dart';
import '../reader/reader_notifier.dart';
import '../reader/scroll_speed.dart';
import '../undo_notice.dart';
import '../version.dart';
import 's3_settings_dialog.dart';

/// The settings (M8): what the reader and the sidecars do by default, which
/// panel detector is in use, and the reading history. A dialog, so `Esc`
/// closes it on the laptop and it fits a phone.
Future<void> showSettings(
  BuildContext context, {
  CoverSizer? covers,
  VoidCallback? onExportSidecars,
  VoidCallback? onExportSettings,
  VoidCallback? onImportSettings,
}) => showDialog<void>(
  context: context,
  builder: (_) => SettingsDialog(
    covers: covers,
    onExportSidecars: onExportSidecars,
    onExportSettings: onExportSettings,
    onImportSettings: onImportSettings,
  ),
);

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key, this.covers, this.onExportSidecars, this.onExportSettings, this.onImportSettings});

  /// The library behind the dialog, for the Cover size buttons; without
  /// one the section is left out.
  final CoverSizer? covers;

  final VoidCallback? onExportSidecars;

  /// Everything but the comics, to one file and back (Back up section).
  final VoidCallback? onExportSettings;
  final VoidCallback? onImportSettings;

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  bool? _wholePage;
  bool? _pauseWhole;
  double? _pauseSeconds;
  bool? _cleanUp;
  bool? _continueAtStart;
  bool? _sidecars;
  String? _sidecarDir;
  bool _moving = false;
  String? _detector;
  S3Fields? _s3;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final whole = await settings.loadBool(SettingsStore.wholePageSteps);
    final pause = await settings.loadBool(SettingsStore.pauseWhole);
    final seconds = SettingsStore.parseSeconds(await settings.loadString(SettingsStore.pauseSeconds));
    final cleanUp = await settings.loadBool(SettingsStore.cleanUp);
    final continueAtStart = await settings.loadBool(SettingsStore.continueAtStart);
    final sidecars = await settings.loadBool(SettingsStore.writeSidecars);
    final sidecarDir = await settings.loadString(SettingsStore.sidecarDir);
    final detector = await ref.read(panelDetectorProvider.future);
    final s3 = await ref.read(s3SettingsProvider).load();
    if (!mounted) return;
    setState(() {
      _wholePage = whole ?? true;
      _pauseWhole = pause ?? true;
      _pauseSeconds = seconds ?? const ReaderState().pauseSeconds;
      _cleanUp = cleanUp ?? false;
      _continueAtStart = continueAtStart ?? true;
      _sidecars = sidecars ?? true;
      _sidecarDir = sidecarDir;
      _s3 = s3;
      _detector = detector.model == null
          ? 'Classic computer vision. Build with the trained model for balloons and better panels (see "The panel detector" in the guide).'
          : 'The trained model: ${detector.model!.path}';
    });
  }

  Future<void> _set(String key, bool value) async {
    await ref.read(settingsStoreProvider).saveBool(key, value);
    await _load();
  }

  /// Asks for the folder to keep sidecars in: the system's folder picker
  /// on the laptop, a path on the phone, which has none that gives one.
  Future<String?> _pickFolder() async {
    if (!Platform.isAndroid) return getDirectoryPath(confirmButtonText: 'Keep comic data here');
    final field = TextEditingController(text: _sidecarDir ?? '/storage/emulated/0/ComicRedr');
    final dir = await showDialog<String>(
      context: context,
      builder: (context) => DialogHotkeys(
        child: AlertDialog(
          title: const Text('Keep comic data in'),
          content: TextField(
            key: const Key('sidecarDir-field'),
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Folder'),
            // Enter in the field is the dialog's button.
            onSubmitted: (text) => Navigator.pop(context, text.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Mnemonic('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: const Mnemonic('Use')),
          ],
        ),
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
        builder: (context) => DialogHotkeys(
          child: AlertDialog(
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
                child: const Mnemonic('Leave them'),
              ),
              FilledButton(
                key: const Key('sidecarMove-move'),
                autofocus: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Mnemonic('Move'),
              ),
            ],
          ),
        ),
      );
      if (move != true) return;
      final moved = await sync.moveAll(from: old, to: dir);
      final rest = moved < n ? '; the rest could not be moved' : '';
      showNotice(messenger, 'Moved $moved of $files$rest', mustRead: moved < n);
    } catch (e) {
      showNotice(messenger, 'Could not change where comic data is kept: $e', mustRead: true);
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
      builder: (context) => DialogHotkeys(
        child: AlertDialog(
          title: const Text('Clear reading history?'),
          content: const Text('Your positions, bookmarks and collections stay.'),
          actions: [
            // Cancel has the focus, so Enter clears nothing by accident.
            TextButton(
              key: const Key('clearHistory-cancel'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Mnemonic('Cancel'),
            ),
            FilledButton(
              key: const Key('clearHistory-clear'),
              onPressed: () => Navigator.pop(context, true),
              child: const Mnemonic('Clear', letter: 'l'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final db = ref.read(databaseProvider);
    await db.delete(db.readLog).go();
    if (mounted) showNotice(ScaffoldMessenger.of(context), 'Reading history cleared');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DialogHotkeys(
      child: AlertDialog(
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
                      ..._pagesPart(context, theme),
                      ..._guidedPart(context, theme),
                      ..._libraryPart(theme),
                      ..._sidecarsPart(context, theme),
                      ..._sidecarPlacePart(context, theme),
                      ..._touchAndHistoryPart(context, theme),
                      ..._backUpPart(context, theme),
                      ..._s3Part(context, theme),
                      const SizedBox(height: 16),
                      Text('ComicRedr $appVersion', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            key: const Key('setting-close'),
            // The focus starts here: Enter closes, Tab goes on to the first
            // setting, Shift+Tab to the last.
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Mnemonic('Close'),
          ),
        ],
      ),
    );
  }

  /// A section's title.
  Widget _heading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
    child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
  );

  /// Whether the comic read last opens at start, and the cover size (only
  /// with the library behind the dialog). Between Guided view and Sidecars,
  /// so what the e2e scripts click above it, counted from the top, has not
  /// moved.
  List<Widget> _libraryPart(ThemeData theme) => [
    _heading(theme, 'Library'),
    SwitchListTile(
      key: const Key('setting-continueAtStart'),
      contentPadding: EdgeInsets.zero,
      title: const Text('Open the comic read last when ComicRedr starts'),
      subtitle: const Text('At the page where you left it, as C does. A comic you open ComicRedr with opens instead.'),
      value: _continueAtStart!,
      onChanged: (v) => _set(SettingsStore.continueAtStart, v),
    ),
    if (widget.covers case final covers?) _CoverSizePicker(covers: covers),
  ];

  /// Clean up and the scroll pickers.
  List<Widget> _pagesPart(BuildContext context, ThemeData theme) => [
    _heading(theme, 'Pages'),
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
    _ScrollSpeedPicker(),
  ];

  /// Guided view: the whole page before and after its panels, the quick step that
  /// stays and how quick, and the detector in use.
  List<Widget> _guidedPart(BuildContext context, ThemeData theme) => [
    _heading(theme, 'Guided view'),
    SwitchListTile(
      key: const Key('setting-wholePage'),
      contentPadding: EdgeInsets.zero,
      title: const Text('Show each page whole before and after its panels'),
      subtitle: const Text('w switches it while reading'),
      value: _wholePage!,
      onChanged: (v) => _set(SettingsStore.wholePageSteps, v),
    ),
    SwitchListTile(
      key: const Key('setting-pauseWhole'),
      contentPadding: EdgeInsets.zero,
      title: const Text('On a page without panels, a quick step stays'),
      subtitle: const Text(
        'The background turns wine red. A step within the time below zooms the page out and back '
        'and stays; the next one turns. After it a step turns at once. W switches it while reading.',
      ),
      value: _pauseWhole!,
      onChanged: (v) => _set(SettingsStore.pauseWhole, v),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: SegmentedButton<double>(
        key: const Key('setting-pauseSeconds'),
        showSelectedIcon: _roomForTicks(context),
        segments: [for (final s in pauseSecondsChoices) ButtonSegment(value: s, label: Text('${_seconds(s)} s'))],
        // A value set by hand in another build shows no segment.
        selected: {if (pauseSecondsChoices.contains(_pauseSeconds)) _pauseSeconds!},
        emptySelectionAllowed: true,
        onSelectionChanged: _pauseWhole!
            ? (v) async {
                if (v.isEmpty) return;
                await ref.read(settingsStoreProvider).saveString(SettingsStore.pauseSeconds, _seconds(v.first));
                await _load();
              }
            : null,
      ),
    ),
    Text('Panel detector', style: theme.textTheme.bodyMedium),
    Text(_detector ?? '', key: const Key('setting-detector'), style: theme.textTheme.bodySmall),
  ];

  /// Sidecars: whether they are written, and beside the comics or in one folder.
  List<Widget> _sidecarsPart(BuildContext context, ThemeData theme) => [
    _heading(theme, 'Sidecars'),
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
        onSelectionChanged: _moving ? null : (v) => v.first ? _chooseSidecarDir() : _setSidecarDir(null),
      ),
    ),
  ];

  /// Where the sidecar folder is (Change…, Alt+G), and the export of them all
  /// (Alt+X).
  List<Widget> _sidecarPlacePart(BuildContext context, ThemeData theme) => [
    if (_sidecarDir case final dir?)
      Row(
        children: [
          Expanded(
            child: Text(dir, key: const Key('setting-sidecarDir'), style: theme.textTheme.bodySmall),
          ),
          TextButton(
            key: const Key('setting-sidecarDir-change'),
            onPressed: _moving ? null : _chooseSidecarDir,
            child: const Mnemonic('Change…', letter: 'g'),
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
          label: const Mnemonic('Export sidecars to a folder…', letter: 'x'),
        ),
      ),
  ];

  /// The touch preset, and Clear reading history (Alt+H).
  List<Widget> _touchAndHistoryPart(BuildContext context, ThemeData theme) => [
    _heading(theme, 'Touch'),
    _TouchPicker(),
    _heading(theme, 'Reading history'),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: const Key('setting-clearHistory'),
        onPressed: _clearHistory,
        icon: const Icon(Icons.delete_sweep_outlined),
        label: const Mnemonic('Clear reading history', letter: 'h'),
      ),
    ),
  ];

  /// Export and Import settings, where the app can do them.
  List<Widget> _backUpPart(BuildContext context, ThemeData theme) => [
    if (widget.onExportSettings != null || widget.onImportSettings != null) ...[
      _heading(theme, 'Back up'),
      Text(
        'Settings, library folders, keys.toml, positions, bookmarks, collections, edits, completed marks and '
        'reading history in one file, to bring back after a reinstall or on another device.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (widget.onExportSettings case final export?)
            OutlinedButton.icon(
              key: const Key('setting-exportSettings'),
              onPressed: () {
                Navigator.pop(context);
                export();
              },
              icon: const Icon(Icons.upload_file),
              label: const Mnemonic('Export settings…'),
            ),
          if (widget.onImportSettings case final import?)
            OutlinedButton.icon(
              key: const Key('setting-importSettings'),
              onPressed: () {
                Navigator.pop(context);
                import();
              },
              icon: const Icon(Icons.download),
              label: const Mnemonic('Import settings…'),
            ),
        ],
      ),
    ],
  ];

  /// S3 sync: whether it is on, and its own dialog (Alt+S).
  List<Widget> _s3Part(BuildContext context, ThemeData theme) => [
    _heading(theme, 'S3 sync'),
    Text(
      _s3?.isSet == true
          ? 'On: ${_s3!.bucket} on ${Uri.tryParse(_s3!.endpoint)?.host ?? _s3!.endpoint}'
          : 'Off. Upload comics and their sidecars to your own S3 bucket to read on where you left '
                'off on another device.',
      key: const Key('setting-s3'),
      style: theme.textTheme.bodySmall,
    ),
    const SizedBox(height: 6),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: const Key('setting-s3-setUp'),
        onPressed: () async {
          if (await showS3Settings(context) == true) await _load();
        },
        icon: const Icon(Icons.cloud_outlined),
        label: Mnemonic(_s3?.isSet == true ? 'Change S3 sync…' : 'Set up S3 sync…', letter: 's'),
      ),
    ),
  ];
}

/// What Settings' Cover size buttons need of the library: the steps `+`
/// `-` and `=` take there, with the same limits, saved the same way
/// (`library.coverSize`). The library screen is one. Its listeners are
/// told when any of the getters has changed, whatever changed it: a press
/// here, a key, the window's width, covers coming or going.
abstract interface class CoverSizer implements Listenable {
  /// How many covers a row there are; null while no grid of covers is on
  /// screen (a list tab, an empty tab or library, a search that found
  /// nothing), when nothing can be sized.
  int? get coversPerRow;

  /// Not at the biggest yet, and not at the smallest.
  bool get canGrowCovers;
  bool get canShrinkCovers;

  /// Another size than the usual one is kept.
  bool get coversZoomed;

  /// Bigger covers (fewer a row) for [by] > 0, smaller for [by] < 0.
  void zoomCovers(int by);

  /// The usual size again.
  void resetCovers();
}

/// Sizes the library's covers with two buttons, for a phone in a hand that
/// cannot pinch and has no `+` key. The covers behind the dialog change at
/// each press, and the line says how many a row there are now: it listens
/// to the library ([CoverSizer]), so it also follows the window's width
/// and comics arriving while Settings is open.
///
/// The line is on its own above the buttons, and they wrap: beside them it
/// had 11 px left in a 400 px wide phone and overflowed below 360.
class _CoverSizePicker extends StatelessWidget {
  const _CoverSizePicker({required this.covers});

  final CoverSizer covers;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: covers,
    builder: (context, _) {
      final theme = Theme.of(context);
      final n = covers.coversPerRow;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            n == null ? 'Cover size' : 'Cover size: $n a row',
            key: const Key('setting-coverSize'),
            style: theme.textTheme.bodyLarge,
          ),
          _buttons(context, n),
          Text(
            n == null
                ? 'No covers show behind Settings now (a list, an empty tab, a search that found nothing), so '
                      'there is nothing to size.'
                : 'One size for every tab of covers. In the library + - and = do the same, and so do Ctrl with '
                      'the wheel and a pinch with two fingers.',
            key: const Key('setting-coverSize-help'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    },
  );

  /// Smaller, bigger and Usual size, each off when it would change
  /// nothing; on a second line when the window or big letters leave no
  /// room for all three. The two with a picture and no label have their
  /// letters from a [DialogKey] (Alt+M, Alt+B), named in the tooltip with
  /// the library's own keys, which do not arrive behind the dialog.
  Widget _buttons(BuildContext context, int? n) {
    final keys = KeyHints.of(context);
    final smaller = covers.canShrinkCovers ? () => covers.zoomCovers(-1) : null;
    final bigger = covers.canGrowCovers ? () => covers.zoomCovers(1) : null;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        DialogKey(
          letter: 'm',
          onPressed: smaller,
          child: IconButton(
            key: const Key('setting-coverSize-smaller'),
            icon: const Icon(Icons.zoom_out),
            tooltip: 'Smaller covers (Alt+M; ${keys.hint(ReaderIntent.zoomOut) ?? '-'} in the library)',
            onPressed: smaller,
          ),
        ),
        DialogKey(
          letter: 'b',
          onPressed: bigger,
          child: IconButton(
            key: const Key('setting-coverSize-bigger'),
            icon: const Icon(Icons.zoom_in),
            tooltip: 'Bigger covers (Alt+B; ${keys.hint(ReaderIntent.zoomIn) ?? '+'} in the library)',
            onPressed: bigger,
          ),
        ),
        TextButton(
          key: const Key('setting-coverSize-usual'),
          onPressed: n != null && covers.coversZoomed ? covers.resetCovers : null,
          child: const Mnemonic('Usual size'),
        ),
      ],
    );
  }
}

/// Picks how fast the arrow keys scroll a zoomed page and how smoothly
/// they glide, five notches each.
class _ScrollSpeedPicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final speed = ref.watch(scrollSpeedProvider);
    final smoothness = ref.watch(scrollSmoothnessProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Smooth scrolling speed: ${speed.label}', style: theme.textTheme.bodyLarge),
          Slider(
            key: const Key('setting-scrollSpeed'),
            value: speed.index.toDouble(),
            max: ScrollSpeed.values.length - 1.0,
            divisions: ScrollSpeed.values.length - 1,
            label: speed.label,
            onChanged: (v) => ref.read(scrollSpeedProvider.notifier).pick(ScrollSpeed.values[v.round()]),
          ),
          Text(
            'How far an arrow key moves a zoomed page; a held key goes faster too. g+ and g- change it '
            'while reading.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text('Smooth scrolling smoothness: ${smoothness.label}', style: theme.textTheme.bodyLarge),
          Slider(
            key: const Key('setting-scrollSmoothness'),
            value: smoothness.index.toDouble(),
            max: ScrollSmoothness.values.length - 1.0,
            divisions: ScrollSmoothness.values.length - 1,
            label: smoothness.label,
            onChanged: (v) => ref.read(scrollSmoothnessProvider.notifier).pick(ScrollSmoothness.values[v.round()]),
          ),
          Text(
            'How softly the page starts and stops: crisp stops almost at once, smoothest eases in and '
            'out. g> and g< change it while reading.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
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
/// [s] as the settings store and the dialog write it: `2`, `1.5`.
String _seconds(double s) => s == s.roundToDouble() ? '${s.round()}' : '$s';

bool _roomForTicks(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;
