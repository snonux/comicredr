import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader_input/reader_input.dart';

import 'grid_zoom.dart';
import 'help_zoom.dart';
import 'version.dart';

/// The `?` overlay, generated from the same table the app binds from, so it
/// cannot drift from the real keys. `/` searches it: fuzzy words, or a
/// regular expression between slashes. Esc clears the search, then closes.
///
/// Its text has sizes ([HelpZoom], task 163): the zoom keys (`+` `-` `=`
/// unless keys.toml says otherwise) reach it as intents through the app,
/// which owns the size and hands it in as [step]; Ctrl and the wheel, a
/// touchpad pinch and two fingers on a touchscreen ask for a step through
/// [onStep]. While the search field has the cursor those keys are typing,
/// as everywhere in the app, so `+` and `-` can be searched for; Enter
/// keeps the filter and gives the keys back, and then they size the text.
class KeymapOverlay extends StatefulWidget {
  const KeymapOverlay({
    super.key,
    required this.keymap,
    this.keysFile,
    this.dataDir,
    this.warnings = const [],
    this.step = HelpZoom.usual,
    this.onStep,
    this.onDone,
  });

  final Keymap keymap;

  /// The `keys.toml` the keymap was read from, if there was one.
  final String? keysFile;

  /// Where the app keeps its index, covers and thumbnails.
  final String? dataDir;

  /// What was wrong in that file.
  final List<String> warnings;

  /// How big the text is: a step of [HelpZoom.scales].
  final int step;

  /// Asked for another step by the wheel or a pinch; answers with the step
  /// the text has from now on (kept within the row), which [step] only
  /// says once the overlay is built again.
  final int Function(int step)? onStep;

  /// Called when the search field hands the keys back to the reader.
  final VoidCallback? onDone;

  @override
  State<KeymapOverlay> createState() => KeymapOverlayState();
}

class KeymapOverlayState extends State<KeymapOverlay> {
  final _query = TextEditingController();
  final _field = FocusNode(debugLabel: 'keymap-search');
  final _scroll = ScrollController();
  bool _searching = false;

  /// The key column's width and the narrowest the descriptions beside it
  /// may get, both at the usual text size; they grow with the text.
  static const _keysWidth = 200.0;
  static const _leastText = 70.0;
  static const _side = 24.0;

  /// The factor on the usual text size.
  double get _scale => HelpZoom.scales[HelpZoom.clamp(widget.step)];

  @override
  void didUpdateWidget(KeymapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step) _keepPlace();
  }

  /// The text changed size, and with it the height of every row: the list
  /// goes to the same share of the way down it was at, so about the same
  /// keys stay on screen. (About: the list only knows the heights of the
  /// rows it has laid out and estimates the rest.)
  void _keepPlace() {
    if (!_scroll.hasClients || _scroll.position.maxScrollExtent <= 0) return;
    final share = _scroll.offset / _scroll.position.maxScrollExtent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(share * _scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// `/` while the overlay is open.
  void startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _field.requestFocus();
    });
  }

  /// Esc: clears a search first. Returns false when there was none, and
  /// the overlay should close.
  bool back() {
    if (!_searching && _query.text.isEmpty) return false;
    _stopSearch(clear: true);
    return true;
  }

  void _stopSearch({required bool clear}) {
    setState(() {
      if (clear) {
        _query.clear();
        _searching = false;
      }
    });
    _field.unfocus();
    widget.onDone?.call();
  }

  /// [GridZoomArea] counts in columns, where one fewer is a step bigger:
  /// the largest text is one "column", each step smaller one more. That
  /// way the help gets the grids' Ctrl+wheel and pinch handling as it is.
  static int _columnsOf(int step) => HelpZoom.largest - HelpZoom.clamp(step) + 1;

  int _onColumns(int columns) {
    final asked = HelpZoom.largest + 1 - columns;
    return _columnsOf(widget.onStep?.call(asked) ?? widget.step);
  }

  /// The text scaler for everything in the overlay: the system's, times
  /// the help's own factor. At the usual size it is the system's untouched.
  /// Otherwise the system's scaling is taken as what it does to 14 px text
  /// (the list's size), since two scalers cannot be multiplied in general.
  TextScaler _scaler(BuildContext context) {
    final system = MediaQuery.textScalerOf(context);
    return _scale == 1 ? system : TextScaler.linear(system.scale(14) / 14 * _scale);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = searchKeymap(widget.keymap, _query.text);
    return Positioned.fill(
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        label: 'Keyboard shortcuts',
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.96),
          child: GridZoomArea(
            columns: _columnsOf(widget.step),
            onColumns: _onColumns,
            builder: (context, physics) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: _scaler(context)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_filtering)
                    Padding(padding: const EdgeInsets.fromLTRB(_side, 16, _side, 0), child: _search(found)),
                  Expanded(child: Stack(children: [_list(theme, found, physics), _version(theme)])),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The search field shows: `/` was pressed, or a filter is kept.
  bool get _filtering => _searching || _query.text.isNotEmpty;

  /// The search field, fixed above the list so it stays in reach.
  Widget _search(KeymapSearch found) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _stopSearch(clear: true)},
    child: TextField(
      key: const Key('keymap-search'),
      controller: _query,
      focusNode: _field,
      autofocus: true,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search: words, fuzzy (fulscr), or /regex/',
        errorText: found.error,
        isDense: true,
      ),
      onChanged: (_) => setState(() {}),
      // Enter keeps the filter and hands the keys back.
      onSubmitted: (_) => _stopSearch(clear: false),
    ),
  );

  /// "Keys · / searches · + - = text size · Esc closes", the size keys
  /// being the first one bound to each zoom intent, so the line is right
  /// for a keys.toml of one's own; left out when none is bound.
  String get _title {
    final entries = keymapEntries(widget.keymap);
    final size = [
      for (final intent in const [ReaderIntent.zoomIn, ReaderIntent.zoomOut, ReaderIntent.zoomReset])
        for (final e in entries)
          if (e.intent == intent && e.keys.isNotEmpty) e.keys.first,
    ];
    return ['Keys', '/ searches', if (size.isNotEmpty) '${size.join(' ')} text size', 'Esc closes'].join('  ·  ');
  }

  /// Above the keys: the title with the keys that work here (not while the
  /// search field is up), the keys file with what is wrong in it, and where
  /// the app keeps its data.
  List<Widget> _notes(ThemeData theme) => [
    if (!_filtering)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(_title, key: const Key('keymap-title'), style: theme.textTheme.titleMedium),
      ),
    if (widget.keysFile != null || widget.warnings.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          [if (widget.keysFile != null) 'Keys from ${widget.keysFile}', ...widget.warnings].join('\n'),
          key: const Key('keymap-file'),
          style: theme.textTheme.bodySmall?.copyWith(color: widget.warnings.isEmpty ? null : theme.colorScheme.error),
        ),
      ),
    if (widget.dataDir case final dir?)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Library, settings, covers and history are kept in $dir; '
          'everything else about a comic is in its sidecar.',
          key: const Key('app-data'),
          style: theme.textTheme.bodySmall,
        ),
      ),
    const SizedBox(height: 12),
  ];

  /// Everything that scrolls: the title and notes, then the keys, with
  /// [physics] (which stop it while Ctrl makes the wheel size the text, or
  /// two fingers pinch). The title and notes are in the list and not fixed
  /// above it, as they were before the text had sizes: at three times the
  /// size they fill a small window, and the keys would have no room left.
  Widget _list(ThemeData theme, KeymapSearch found, ScrollPhysics? physics) => LayoutBuilder(
    builder: (context, box) {
      // Keys beside what they do while that leaves the text some room; in
      // a narrow window or with big text, keys above the text, so a row
      // never overflows.
      final beside = box.maxWidth - 2 * _side - _keysWidth * _scale >= _leastText * _scale;
      return ListView(
        key: const Key('keymap-list'),
        controller: _scroll,
        physics: physics,
        padding: const EdgeInsets.fromLTRB(_side, 0, _side, 40),
        children: [
          ..._notes(theme),
          if (found.entries.isEmpty && found.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text('Nothing matches "${_query.text}"', textAlign: TextAlign.center),
            ),
          for (final e in found.entries) ...[
            if (e.intent == ReaderIntent.regionWhole && _query.text.isEmpty) _partsNote(theme),
            _row(e, beside: beside),
          ],
        ],
      );
    },
  );

  Widget _partsNote(ThemeData theme) => Padding(
    key: const Key('keymap-parts'),
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      'Part of the page: 11 whole page, 00 leave; letter keys H1 B1 L1 Q1, '
      'or two quick digits (21 halves … 54 quarters), numbered top to bottom, left to right',
      style: theme.textTheme.titleSmall,
    ),
  );

  /// One action: its keys and what it does, side by side when [beside],
  /// else the keys on a line of their own above.
  Widget _row(KeymapEntry e, {required bool beside}) {
    final keys = Text(e.keys.isEmpty ? '(no key)' : e.keys.join('  '), style: const TextStyle(fontFamily: 'monospace'));
    final what = Text(e.intent.description);
    return MergeSemantics(
      child: Padding(
        key: ValueKey('keymap-${e.intent.name}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: beside
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _keysWidth * _scale, child: keys),
                  Expanded(child: what),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  keys,
                  Padding(
                    padding: const EdgeInsets.only(left: _side),
                    child: what,
                  ),
                ],
              ),
      ),
    );
  }

  /// In a corner, so the keymap list keeps its whole height.
  Widget _version(ThemeData theme) => Positioned(
    right: _side,
    bottom: 16,
    child: Text('ComicRedr $appVersion', key: const Key('keymap-version'), style: theme.textTheme.titleSmall),
  );
}
