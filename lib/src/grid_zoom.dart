import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How a grid of tiles zooms: a step is one column more or fewer, and what
/// is kept is the tile width that gives, so a wider window later fits more
/// tiles of that size. Shared by the page grid (`p`) and the library's
/// cover grids, so `+` `-`, Ctrl and the wheel and a pinch step alike in
/// both.
class GridZoom {
  const GridZoom({required this.gap, required this.smallest, this.largest = double.infinity});

  /// The space between two tiles.
  final double gap;

  /// Tiles narrower than this say nothing: the most columns come from it.
  final double smallest;

  /// Tiles wider than this are no use: the fewest columns come from it.
  /// Without one the grid zooms in to one tile a row.
  final double largest;

  /// The most columns [inner] (the grid's width inside its padding) takes;
  /// never fewer than two, so there is always a step to take.
  int most(double inner) => math.max(2, ((inner + gap) / (smallest + gap)).floor());

  /// The fewest columns: one, unless that would make a tile wider than
  /// [largest].
  int fewest(double inner) =>
      largest.isFinite ? ((inner + gap) / (largest + gap)).ceil().clamp(1, most(inner)).toInt() : 1;

  /// [columns] brought within what [inner] allows.
  int clamp(double inner, int columns) => columns.clamp(fewest(inner), most(inner)).toInt();

  /// The columns of tiles about [target] wide. A hair over, so a width
  /// saved from this very column count gives it back despite rounding.
  int columns(double inner, double target) => clamp(inner, ((inner + gap) / (target + gap) + 0.01).floor());

  /// How wide a tile is with [columns] of them a row: the size to keep.
  double tileWidth(double inner, int columns) => (inner - (columns - 1) * gap) / columns;

  /// A pinch is a step each time the fingers spread by a quarter (positive)
  /// or close by as much (negative).
  static int pinchSteps(double scale) => (math.log(scale) / math.log(1.25)).truncate();
}

/// Wraps a scrolling grid so that Ctrl and the wheel, a touchpad pinch and
/// two fingers on a touchscreen zoom it. It only watches the pointers
/// (a [Listener]), so one finger scrolls, taps and long presses as before;
/// the grid is handed the physics to use, which stop it scrolling while two
/// fingers pinch or Ctrl makes the wheel zoom.
class GridZoomArea extends StatefulWidget {
  const GridZoomArea({super.key, required this.columns, required this.onColumns, required this.builder});

  /// The columns the grid has now.
  final int columns;

  /// Asked for another column count; the grid clamps it to what it allows.
  final ValueChanged<int> onColumns;

  /// Builds the grid with [physics]: null for its usual ones.
  final Widget Function(BuildContext context, ScrollPhysics? physics) builder;

  @override
  State<GridZoomArea> createState() => GridZoomAreaState();
}

class GridZoomAreaState extends State<GridZoomArea> {
  /// Ctrl is held: the wheel zooms, so the grid must not scroll with it.
  bool _ctrl = false;

  /// Two fingers on the grid: their first spread, and the columns then.
  final _fingers = <int, Offset>{};
  double? _pinchFrom;
  int _pinchColumns = 1;
  bool _pinched = false;

  /// A second finger came down in the touch that is on the grid, or that
  /// just left it: its taps and long presses are part of a pinch and mean
  /// nothing. Still true when the last finger lifts (a tap is only
  /// recognised after that), until the next touch starts.
  bool get pinched => _pinched;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Never takes the key: it only follows Ctrl.
  bool _onKey(KeyEvent e) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrl && mounted) setState(() => _ctrl = ctrl);
    return false;
  }

  /// Bigger tiles (fewer columns) for [by] > 0, smaller for [by] < 0.
  void _step(int by) => widget.onColumns(widget.columns - by);

  /// Ctrl and the wheel zooms; the wheel alone scrolls as usual.
  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) => _step(e.scrollDelta.dy < 0 ? 1 : -1));
    } else if (e is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) => _step(e.scale > 1 ? 1 : -1));
    }
  }

  /// The columns the pinch started with, less a column for each step the
  /// fingers spread; a touchpad pinch (pan-zoom events) the same way.
  void _pinch(double scale) => widget.onColumns(_pinchColumns - GridZoom.pinchSteps(scale));

  void _fingerDown(PointerDownEvent e) {
    // A new touch or click: the last pinch is over.
    if (_fingers.isEmpty) _pinched = false;
    if (e.kind != PointerDeviceKind.touch) return;
    _fingers[e.pointer] = e.position;
    if (_fingers.length == 2) {
      setState(() {
        _pinched = true;
        _pinchFrom = _spread;
        _pinchColumns = widget.columns;
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

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _onSignal,
    onPointerDown: _fingerDown,
    onPointerMove: _fingerMove,
    onPointerUp: _fingerUp,
    onPointerCancel: _fingerUp,
    onPointerPanZoomStart: (_) => _pinchColumns = widget.columns,
    onPointerPanZoomUpdate: (e) => _pinch(e.scale),
    // Two fingers pinch; they do not scroll meanwhile. Nor does the wheel
    // while Ctrl makes it zoom.
    child: widget.builder(context, _pinchFrom != null || _ctrl ? const NeverScrollableScrollPhysics() : null),
  );
}
