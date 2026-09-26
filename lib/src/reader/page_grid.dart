import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/settings_store.dart';
import 'reader_notifier.dart';
import 'thumbnails.dart';

/// The open book's pages as a grid of thumbnails (`p`), to see pages before
/// jumping to one. The current page is outlined in blue and the selection
/// in amber, which shows on paper and art alike; bookmarked pages carry a
/// bookmark and marked ones their letter. Arrows and `hjkl` move the
/// selection, Enter, a click or a tap jumps, Esc or back closes.
///
/// The grid zooms like the page: `+` and `-`, Ctrl and the scroll wheel, a
/// touchpad or two-finger pinch, or the buttons in its header, from many
/// small tiles to one page a row. The selected page stays in view, and the
/// size is remembered.
///
/// Tiles are built only as they scroll into view, each thumbnail decoded at
/// the tile's own size and dropped from the image cache when its tile goes,
/// so a long book costs no more memory than one screenful. Zoomed in, a
/// tile shows the small thumbnail at once and swaps in a sharper one made
/// for its size (512 or 1024 px wide) when that is ready.
class PageGrid extends ConsumerStatefulWidget {
  const PageGrid({super.key, required this.onPick, required this.onClose, this.onDetails});

  final ValueChanged<int> onPick;
  final VoidCallback onClose;

  /// Opens the book's details (`I`): the way there on a phone, whose
  /// status line has no room for the button.
  final VoidCallback? onDetails;

  @override
  ConsumerState<PageGrid> createState() => PageGridState();
}

class PageGridState extends ConsumerState<PageGrid> {
  final _scroll = ScrollController();
  late int _selected = ref.read(readerProvider).page;
  int _columns = 1;
  double _rowExtent = 1;
  double _tileWidth = 1;
  bool _placed = false;

  /// How wide a tile aims to be, in logical pixels: the zoom. Null for
  /// the default, about three columns on a phone and more on the laptop.
  late double? _target = ref.read(_lastZoom).target;

  /// Ctrl is held: the wheel zooms, so the grid must not scroll with it.
  bool _ctrl = false;

  /// The most columns: tiles narrower than this say nothing.
  int _maxColumns = 2;
  static const _smallest = 56.0;

  /// Two fingers on the grid: their first spread, and the columns then.
  final _fingers = <int, Offset>{};
  double? _pinchFrom;
  int _pinchColumns = 1;

  static const _pad = 12.0;
  static const _gap = 8.0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(
      ref
          .read(settingsStoreProvider)
          .loadString(SettingsStore.gridZoom)
          .then((v) {
            final target = double.tryParse(v ?? '');
            if (target == null || !mounted || _target != null) return;
            setState(() => _target = ref.read(_lastZoom).target = target);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _centre();
            });
          })
          .catchError((Object e) => debugPrint('Could not read the grid size: $e')),
    );
  }

  double _defaultTarget(BuildContext context) => MediaQuery.sizeOf(context).width < 600 ? 110 : 150;

  /// Bigger thumbnails (fewer columns) for [by] > 0, smaller for [by] < 0.
  void zoom(int by) => _setColumns(_columns - by);

  /// Zooms to [columns] a row. What is kept is the tile width that gives,
  /// so a wider window later fits more of them.
  void _setColumns(int columns, {bool reset = false}) {
    final next = columns.clamp(1, _maxColumns);
    if (next == _columns && !reset) return;
    final inner = _inner;
    final target = reset ? null : (inner - (next - 1) * _gap) / next;
    setState(() => _target = ref.read(_lastZoom).target = target);
    unawaited(
      ref
          .read(settingsStoreProvider)
          .saveString(SettingsStore.gridZoom, target?.toStringAsFixed(1))
          .catchError((Object e) => debugPrint('Could not save the grid size: $e')),
    );
    // The rows moved: the selected page goes back to the middle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centre();
    });
  }

  double _inner = 0;

  /// Ctrl and the wheel zooms; the wheel alone scrolls as usual.
  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) => zoom(e.scrollDelta.dy < 0 ? 1 : -1));
    } else if (e is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) => zoom(e.scale > 1 ? 1 : -1));
    }
  }

  /// A pinch takes a column off each time the fingers spread by a quarter,
  /// and adds one each time they close by as much; a touchpad pinch
  /// (pan-zoom events) the same way.
  void _pinch(double scale) {
    final steps = (math.log(scale) / math.log(1.25)).truncate();
    _setColumns(_pinchColumns - steps);
  }

  void _fingerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _fingers[e.pointer] = e.position;
    if (_fingers.length == 2) {
      setState(() {
        _pinchFrom = _spread;
        _pinchColumns = _columns;
      });
    }
  }

  void _fingerMove(PointerMoveEvent e) {
    if (!_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.position;
    final from = _pinchFrom;
    if (from != null && from > 0 && _fingers.length == 2) _pinch(_spread / from);
  }

  void _fingerUp(PointerEvent e) {
    _fingers.remove(e.pointer);
    if (_fingers.length < 2 && _pinchFrom != null) setState(() => _pinchFrom = null);
  }

  double get _spread {
    final [a, b] = _fingers.values.take(2).toList();
    return (a - b).distance;
  }

  bool _onKey(KeyEvent e) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrl && mounted) setState(() => _ctrl = ctrl);
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scroll.dispose();
    super.dispose();
  }

  /// Grid intents while it is open; everything else is swallowed, so a key
  /// meant for the page does nothing behind the grid.
  void handle(ReaderCommand c) {
    final s = ref.read(readerProvider);
    final n = s.pageCount;
    if (n == 0) return;
    // Right to left lays the grid out mirrored, so the arrow pointing at a
    // tile still moves to it.
    final mirror = s.rightToLeft ? -1 : 1;
    final screen = math.max(1, _viewport ~/ _rowExtent);
    switch (c.intent) {
      case ReaderIntent.nextStep:
        _select(_selected + mirror * c.times);
      case ReaderIntent.prevStep:
        _select(_selected - mirror * c.times);
      case ReaderIntent.panDown:
        _select(_selected + _columns * c.times);
      case ReaderIntent.panUp:
        _select(_selected - _columns * c.times);
      case ReaderIntent.nextPage:
      case ReaderIntent.halfPageDown:
        _select(_selected + _columns * screen * c.times);
      case ReaderIntent.prevPage:
      case ReaderIntent.halfPageUp:
        _select(_selected - _columns * screen * c.times);
      case ReaderIntent.firstPage:
        _select(0);
      case ReaderIntent.lastPage:
        _select(c.count != null ? c.count! - 1 : n - 1);
      case ReaderIntent.zoomIn:
        zoom(c.times);
      case ReaderIntent.zoomOut:
        zoom(-c.times);
      case ReaderIntent.zoomReset:
        _setColumns(_columns, reset: true);
      case ReaderIntent.activate:
        widget.onPick(_selected);
      case ReaderIntent.back:
      case ReaderIntent.pageGrid:
        widget.onClose();
      default:
        break;
    }
  }

  double get _viewport => _scroll.hasClients ? _scroll.position.viewportDimension : 0;

  void _select(int i) {
    final n = ref.read(readerProvider).pageCount;
    setState(() => _selected = i.clamp(0, n - 1));
    _reveal();
  }

  /// Scrolls just far enough to show the selected tile.
  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _pad + (_selected ~/ _columns) * _rowExtent;
    final bottom = top + _rowExtent - _gap + _pad;
    final at = _scroll.offset;
    final target = top - _pad < at
        ? top - _pad
        : bottom > at + _viewport
        ? bottom - _viewport
        : null;
    if (target == null) return;
    final to = target.clamp(0.0, _scroll.position.maxScrollExtent);
    MediaQuery.disableAnimationsOf(context)
        ? _scroll.jumpTo(to)
        : unawaited(_scroll.animateTo(to, duration: const Duration(milliseconds: 120), curve: Curves.easeOut));
  }

  /// On opening: the current page in the middle of the screen.
  void _centre() {
    if (!_scroll.hasClients) return;
    final top = _pad + (_selected ~/ _columns) * _rowExtent;
    // A row taller than the screen (zoomed right in) shows from its top.
    final at = _rowExtent > _viewport ? top - _pad : top - (_viewport - _rowExtent) / 2;
    _scroll.jumpTo(at.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    final thumbs = ref.watch(thumbnailsProvider);
    final theme = Theme.of(context);
    final n = s.pageCount;
    final bookmarked = {
      for (final b in s.bookmarks)
        if (b.mark == null) b.page,
    };
    final marks = <int, List<String>>{};
    for (final e in s.marks.entries) {
      (marks[e.value.page] ??= []).add(e.key);
    }
    return Material(
      key: const Key('pageGrid'),
      color: Colors.black.withValues(alpha: 0.92),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Pages  ·  ${s.book?.title ?? ''}',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const Key('pageGridZoomOut'),
                  icon: const Icon(Icons.zoom_out),
                  tooltip: 'Smaller pages (-)',
                  onPressed: _columns < _maxColumns ? () => zoom(-1) : null,
                ),
                IconButton(
                  key: const Key('pageGridZoomIn'),
                  icon: const Icon(Icons.zoom_in),
                  tooltip: 'Bigger pages (+)',
                  onPressed: _columns > 1 ? () => zoom(1) : null,
                ),
                if (widget.onDetails != null)
                  IconButton(
                    key: const Key('pageGridDetails'),
                    icon: const Icon(Icons.info_outline),
                    tooltip: 'Details (I)',
                    onPressed: widget.onDetails,
                  ),
                IconButton(
                  key: const Key('pageGridClose'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close (Esc)',
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final target = _target ?? _defaultTarget(context);
                final inner = _inner = constraints.maxWidth - 2 * _pad;
                _maxColumns = math.max(2, ((inner + _gap) / (_smallest + _gap)).floor());
                // A hair over, so a width saved from this very column count
                // gives it back despite rounding.
                _columns = ((inner + _gap) / (target + _gap) + 0.01).floor().clamp(1, _maxColumns);
                _tileWidth = (inner - (_columns - 1) * _gap) / _columns;
                _rowExtent = _tileWidth * 1.5 + _labelHeight + _gap;
                if (!_placed) {
                  _placed = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _centre();
                  });
                }
                final size = Thumbnails.sizeFor(_tileWidth * MediaQuery.devicePixelRatioOf(context));
                return Listener(
                  onPointerSignal: _onSignal,
                  onPointerDown: _fingerDown,
                  onPointerMove: _fingerMove,
                  onPointerUp: _fingerUp,
                  onPointerCancel: _fingerUp,
                  onPointerPanZoomStart: (_) => _pinchColumns = _columns,
                  onPointerPanZoomUpdate: (e) => _pinch(e.scale),
                  child: Directionality(
                    textDirection: s.rightToLeft ? TextDirection.rtl : TextDirection.ltr,
                    child: GridView.builder(
                      controller: _scroll,
                      // Two fingers pinch; they do not scroll meanwhile.
                      // Nor does the wheel while Ctrl makes it zoom.
                      physics: _pinchFrom != null || _ctrl ? const NeverScrollableScrollPhysics() : null,
                      padding: const EdgeInsets.all(_pad),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _columns,
                        mainAxisSpacing: _gap,
                        crossAxisSpacing: _gap,
                        mainAxisExtent: _rowExtent - _gap,
                      ),
                      itemCount: n,
                      itemBuilder: (context, i) => _Tile(
                        // A new tile per zoom, so it asks for its size.
                        key: ValueKey((i, _columns)),
                        index: i,
                        thumbs: thumbs,
                        width: _tileWidth,
                        size: size,
                        current: s.unit.contains(i),
                        selected: i == _selected,
                        bookmarked: bookmarked.contains(i),
                        marks: marks[i] ?? const [],
                        onTap: () => widget.onPick(i),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The grid's zoom from its last opening, so it opens at it at once; the
/// setting brings it back after a restart.
final _lastZoom = Provider((ref) => _Zoom());

/// Forgets the grid size used in this run, so the grid takes the saved one
/// the next time it opens (after an import changed it).
void forgetGridZoom(WidgetRef ref) => ref.invalidate(_lastZoom);

class _Zoom {
  double? target;
}

/// Room under each thumbnail for its page number.
const _labelHeight = 22.0;

class _Tile extends StatefulWidget {
  const _Tile({
    super.key,
    required this.index,
    required this.thumbs,
    required this.width,
    required this.size,
    required this.current,
    required this.selected,
    required this.bookmarked,
    required this.marks,
    required this.onTap,
  });

  final int index;
  final Thumbnails? thumbs;
  final double width;

  /// The thumbnail size (Thumbnails.sizes) sharp enough for this tile.
  final int size;
  final bool current;
  final bool selected;
  final bool bookmarked;
  final List<String> marks;
  final VoidCallback onTap;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  ImageProvider? _image;
  final _shown = <ImageProvider>[];

  @override
  void initState() {
    super.initState();
    final thumbs = widget.thumbs;
    if (thumbs == null) return;
    final sharp = widget.size;
    // A big tile shows the small thumbnail first when it is already on
    // disk, so something shows at once while the sharp one is made.
    if (sharp != thumbs.width && !thumbs.has(widget.index, sharp)) {
      final small = thumbs.pathOf(widget.index);
      unawaited(
        File(small).exists().then((yes) {
          if (yes && mounted && _image == null) _show(small);
        }),
      );
    }
    unawaited(
      thumbs.get(widget.index, size: sharp).then((path) {
        if (path != null && mounted) _show(path);
      }),
    );
  }

  void _show(String path) {
    final image = _provider(path);
    _shown.add(image);
    setState(() => _image = image);
  }

  ImageProvider _provider(String path) {
    final px = (widget.width * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage(FileImage(File(path)), width: px, policy: ResizeImagePolicy.fit);
  }

  @override
  void dispose() {
    widget.thumbs?.cancel(widget.index, size: widget.size);
    // Scrolled away: its pixels leave the image cache with it.
    for (final image in _shown) {
      unawaited(image.evict());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = widget.index + 1;
    final border = widget.selected
        ? Border.all(color: Colors.amber, width: 4)
        : widget.current
        ? Border.all(color: scheme.primary, width: 3)
        : Border.all(color: Colors.white12);
    return Semantics(
      button: true,
      selected: widget.current,
      label: [
        'Page $page',
        if (widget.current) 'current page',
        if (widget.bookmarked) 'bookmarked',
        for (final m in widget.marks) 'mark $m',
      ].join(', '),
      child: InkWell(
        key: Key('pageTile-${widget.index}'),
        onTap: widget.onTap,
        canRequestFocus: false,
        child: ExcludeSemantics(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Colors.white10,
                  // On top of the picture, which fills the tile.
                  foregroundDecoration: BoxDecoration(border: border),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_image case final image?)
                        Image(image: image, fit: BoxFit.contain, gaplessPlayback: true)
                      else
                        const Center(child: Icon(Icons.image_outlined, color: Colors.white24)),
                      if (widget.bookmarked || widget.marks.isNotEmpty)
                        PositionedDirectional(
                          top: 2,
                          end: 2,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final m in widget.marks)
                                Container(
                                  margin: const EdgeInsets.only(right: 2),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  color: scheme.secondaryContainer,
                                  child: Text(m, style: TextStyle(color: scheme.onSecondaryContainer)),
                                ),
                              if (widget.bookmarked)
                                Icon(Icons.bookmark, key: Key('pageBookmark-${widget.index}'), color: scheme.primary),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: _labelHeight,
                child: Center(
                  child: Text(
                    '$page',
                    style: TextStyle(
                      color: widget.current ? scheme.primary : Colors.white70,
                      fontWeight: widget.current ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
