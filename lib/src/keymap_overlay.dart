import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  final _scroll = _PlaceController();
  bool _searching = false;

  /// A key for every item of the list (the title, each note, each action:
  /// [_item]), made when the item is first built, and the keys of the items
  /// the list has now, top to bottom. [_keepPlace] finds the item along
  /// the top of the list by them.
  final _itemKeys = <Object, GlobalKey>{};
  var _order = <GlobalKey>[];

  /// The key column's width and the narrowest the descriptions beside it
  /// may get, both for letters of the list's own size ([_letters], no
  /// scaling by the help or the system); they grow with the letters.
  static const _keysWidth = 200.0;
  static const _leastText = 70.0;
  static const _side = 24.0;

  /// How far beyond the screen the list lays out its items: all the way.
  /// The list is short (102 actions with the default keys, and four items
  /// above them), and laid out lazily it only guessed its length and kept
  /// the rows above the screen where the old text size had put them, so
  /// after a size change no item could be put back where it was
  /// ([_keepPlace]). Only the items on screen are painted. What it costs,
  /// measured in a debug build's widget test at 1280x800 (medians of 30)
  /// against the same list laid out lazily: opening the help 38 ms for
  /// 9 ms, a size step 25 ms for 7 ms. Paid once a `?` and once a step,
  /// not while scrolling.
  static const _wholeList = 1e6;

  /// The size of the list's text before any scaling.
  static const _letters = 14.0;

  /// The help's own factor on the usual text size.
  double get _scale => HelpZoom.scales[HelpZoom.clamp(widget.step)];

  /// What the letters are really multiplied by where [context] is: the
  /// system's text scale times the help's factor, read off the scaler
  /// [_scaler] put over the overlay. The layout goes by this and not by
  /// the help's factor alone: with the system's text at 1.5 one step is
  /// 24 px letters, which need the room of 24 px letters.
  static double _factor(BuildContext context) => MediaQuery.textScalerOf(context).scale(_letters) / _letters;

  @override
  void didUpdateWidget(KeymapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step) _keepPlace();
  }

  /// The text changed size, and with it the height of every item: the
  /// item along the top of the list stays there, as far scrolled into it
  /// as it was (a quarter of it above the edge before, a quarter after).
  /// Any item: an action's row, or the title or a note when the list is
  /// only a little way down. Called before the new layout, so the items
  /// are still where they were.
  ///
  /// The list is put right within the layout that gives the items their
  /// new heights ([_PlaceController.place]), so the first frame at the new
  /// size already shows the same item along the top; a jump after the
  /// frame showed one frame of some other row first.
  ///
  /// By an item and not by the share of the way down the list: rows grow
  /// unevenly (a long description wraps into more lines), so the same
  /// share was several rows away after a step. At the very top the list
  /// stays at the top, the title in sight.
  void _keepPlace() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    final at = _scroll.offset;
    var top = 0.0;
    for (final item in _order) {
      final height = _heightOf(item);
      if (height == null) return;
      // The first item not wholly above the edge.
      if (top + height > at) {
        final into = (at - top) / height;
        _scroll.place = () => _placeOf(item, into);
        // Every size change lays the list out, which takes the place up;
        // should one not, the place must not wait for some later layout.
        WidgetsBinding.instance.addPostFrameCallback((_) => _scroll.place = null);
        return;
      }
      top += height;
    }
  }

  /// How far the list is scrolled when [item] is along its top with [into]
  /// of its height above the edge; null when the list no longer has it.
  /// The items' tops are their heights added up (the list has no padding
  /// above its first item and lays out every item, [_wholeList]), which
  /// can be read while the list is being laid out, as a render object's
  /// size or place in the viewport cannot.
  double? _placeOf(GlobalKey item, double into) {
    var top = 0.0;
    for (final other in _order) {
      final height = _heightOf(other);
      if (height == null) return null;
      if (identical(other, item)) return top + into * height;
      top += height;
    }
    return null;
  }

  /// The height [item] was last laid out with, null while it is not built.
  static double? _heightOf(GlobalKey item) {
    final box = item.currentContext?.findRenderObject();
    return box is _RenderMeasured && box.attached ? box.height : null;
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

  /// The text scaler for the search field and the list: the system's, times
  /// the help's own factor. At the usual size it is the system's untouched.
  /// Otherwise the system's scaling is taken as what it does to the
  /// list's text ([_factor]), since two scalers cannot be multiplied in
  /// general.
  TextScaler _scaler(BuildContext context) {
    final system = MediaQuery.textScalerOf(context);
    return _scale == 1 ? system : TextScaler.linear(_factor(context) * _scale);
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
            builder: (context, physics) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The search and the list in the help's text size; the
                // version under them in the system's, as everywhere else.
                Expanded(
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: _scaler(context)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_filtering)
                          Padding(padding: const EdgeInsets.fromLTRB(_side, 16, _side, 0), child: _search(found)),
                        Expanded(child: _list(theme, found, physics)),
                      ],
                    ),
                  ),
                ),
                _version(theme),
              ],
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
  /// the app keeps its data. Each is an item of the list ([_item]).
  List<Widget> _notes(ThemeData theme) => [
    if (!_filtering)
      _item(
        'title',
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(_title, key: const Key('keymap-title'), style: theme.textTheme.titleMedium),
        ),
      ),
    if (widget.keysFile != null || widget.warnings.isNotEmpty)
      _item(
        'file',
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            [if (widget.keysFile != null) 'Keys from ${widget.keysFile}', ...widget.warnings].join('\n'),
            key: const Key('keymap-file'),
            style: theme.textTheme.bodySmall?.copyWith(color: widget.warnings.isEmpty ? null : theme.colorScheme.error),
          ),
        ),
      ),
    if (widget.dataDir case final dir?)
      _item(
        'data',
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Library, settings, covers and history are kept in $dir; '
            'everything else about a comic is in its sidecar.',
            key: const Key('app-data'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    _item('gap', const SizedBox(height: 12)),
  ];

  /// One item of the list, [child] under the key kept for [id] and
  /// measured: [_keepPlace] goes by the items' heights, top to bottom.
  /// Only called while the list is built, in the order the items show.
  Widget _item(Object id, Widget child) {
    final key = _itemKeys.putIfAbsent(id, GlobalKey.new);
    _order.add(key);
    return _Measured(key: key, child: child);
  }

  /// Everything that scrolls: the title and notes, then the keys, with
  /// [physics] (which stop it while Ctrl makes the wheel size the text, or
  /// two fingers pinch). The title and notes are in the list and not fixed
  /// above it, as they were before the text had sizes: at three times the
  /// size they fill a small window, and the keys would have no room left.
  /// A search that finds nothing says so in the middle of the room under
  /// the notes, as it did in the middle of the list before.
  Widget _list(ThemeData theme, KeymapSearch found, ScrollPhysics? physics) => LayoutBuilder(
    builder: (context, box) {
      // Keys beside what they do while that leaves the text some room; in
      // a narrow window or with big text, keys above the text, so a row
      // never overflows. Big text is the letters as drawn, the system's
      // scaling included.
      final factor = _factor(context);
      final beside = box.maxWidth - 2 * _side - _keysWidth * factor >= _leastText * factor;
      _order = [];
      final items = [
        ..._notes(theme),
        for (final e in found.entries) ...[
          if (e.intent == ReaderIntent.regionWhole && _query.text.isEmpty) _item('parts', _partsNote(theme)),
          _item(e.intent, _row(e, keysWidth: beside ? _keysWidth * factor : null)),
        ],
      ];
      return CustomScrollView(
        key: const Key('keymap-list'),
        controller: _scroll,
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(_wholeList),
        slivers: [
          // No padding above the first item: [_placeOf] counts from there.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_side, 0, _side, 8),
            sliver: SliverList.list(children: items),
          ),
          if (found.entries.isEmpty && found.error == null) _nothing,
        ],
      );
    },
  );

  /// "Nothing matches", in the middle of what the notes leave of the list.
  Widget get _nothing => SliverFillRemaining(
    hasScrollBody: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: _side, vertical: 16),
      child: Center(
        child: Text('Nothing matches "${_query.text}"', key: const Key('keymap-nothing'), textAlign: TextAlign.center),
      ),
    ),
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

  /// One action: its keys and what it does, side by side with the keys in
  /// a column [keysWidth] wide, or without one the keys on a line of their
  /// own above.
  Widget _row(KeymapEntry e, {required double? keysWidth}) {
    final keys = Text(e.keys.isEmpty ? '(no key)' : e.keys.join('  '), style: const TextStyle(fontFamily: 'monospace'));
    final what = Text(e.intent.description);
    return MergeSemantics(
      child: Padding(
        key: ValueKey('keymap-${e.intent.name}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: keysWidth != null
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: keysWidth, child: keys),
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

  /// The version, in the bottom right corner under the list, always in
  /// sight. It has a line of its own there, where it once lay over the
  /// list's last 40 px, and is no part of what the help's text size sizes
  /// ([build] leaves it the system's text scale): it is not help text, and
  /// in the help's biggest letters it took a line 100 px tall from a short
  /// window. Where the window is narrower than the line (a phone with the
  /// system's text set very big) it shrinks to fit, so it is never cut off.
  Widget _version(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(_side, 4, _side, 12),
    child: Align(
      alignment: Alignment.centerRight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          'ComicRedr $appVersion',
          key: const Key('keymap-version'),
          maxLines: 1,
          style: theme.textTheme.titleSmall,
        ),
      ),
    ),
  );
}

/// The help list's scroll controller: [place], when set, is asked once
/// during the list's next layout for where the list should be scrolled to,
/// and the list is laid out there in that same frame.
class _PlaceController extends ScrollController {
  /// Answers with the scroll offset wanted, or null to leave the list be.
  /// Called by the position when the list's items have their new heights.
  double? Function()? place;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _PlacePosition(this, physics: physics, context: context, oldPosition: oldPosition, debugLabel: debugLabel);
}

/// A scroll position that takes [_PlaceController.place] up where the
/// viewport tells it the content's new extent: the items are laid out by
/// then, and answering false makes the viewport lay itself out once more
/// at the corrected offset before anything is painted.
class _PlacePosition extends ScrollPositionWithSingleContext {
  _PlacePosition(this._owner, {required super.physics, required super.context, super.oldPosition, super.debugLabel});

  final _PlaceController _owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final place = _owner.place;
    _owner.place = null;
    final to = place?.call()?.clamp(minScrollExtent, maxScrollExtent);
    if (to != null && (to - pixels).abs() > precisionErrorTolerance) {
      correctPixels(to);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// Notes the height its child is laid out with, where it can be read
/// while an ancestor is still in its layout ([RenderBox.size] cannot).
class _Measured extends SingleChildRenderObjectWidget {
  const _Measured({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasured();
}

class _RenderMeasured extends RenderProxyBox {
  /// The height of the last layout.
  double height = 0;

  @override
  void performLayout() {
    super.performLayout();
    height = size.height;
  }
}
