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

  /// The library's covers: from covers just wide enough for a few letters
  /// of the title up to 480 px, [coversGap] apart.
  static const covers = GridZoom(gap: coversGap, smallest: 72, largest: 480);
  static const coversGap = 12.0;

  /// The page grid (`p`): from tiles too small to say anything up to one
  /// page a row, [pagesGap] apart.
  static const pages = GridZoom(gap: pagesGap, smallest: 56);
  static const pagesGap = 8.0;

  /// The space between two tiles.
  final double gap;

  /// Tiles narrower than this say nothing: the most columns come from it.
  final double smallest;

  /// Tiles wider than this are no use: the fewest columns come from it.
  /// Without one the grid zooms in to one tile a row.
  final double largest;

  /// The most columns [inner] (the grid's width inside its padding) takes;
  /// never fewer than two, so there is always a step to take. Two as well
  /// for a width that is no width (not a number, or nothing).
  int most(double inner) => math.max(2, _whole((inner + gap) / (smallest + gap)));

  /// The fewest columns: one, unless that would make a tile wider than
  /// [largest].
  int fewest(double inner) =>
      largest.isFinite ? _whole(((inner + gap) / (largest + gap)).ceilToDouble()).clamp(1, most(inner)).toInt() : 1;

  /// [columns] brought within what [inner] allows.
  int clamp(double inner, int columns) => columns.clamp(fewest(inner), most(inner)).toInt();

  /// The columns of tiles about [target] wide. A hair over, so a width
  /// worked out from this very column count gives it back despite the
  /// arithmetic's rounding (and one saved to a tenth of a pixel, as an
  /// earlier build did, mostly does).
  ///
  /// Safe for any [target], since it may come from a settings file: one
  /// that is not a number, or not above zero, gives the most columns, an
  /// infinite one the fewest.
  int columns(double inner, double target) {
    if (target.isNaN || target <= 0) return most(inner);
    return clamp(inner, _whole((inner + gap) / (target + gap) + 0.01));
  }

  /// How many tiles exactly [width] wide fit in a row, with no allowance
  /// for rounding and no limits: what a grid's usual size is counted
  /// with. That size was never worked out from a column count, so it has
  /// no rounding to make up for, and the hair [columns] adds would show a
  /// tile more than the grid always did in the last pixel or two below
  /// each further column (the covers: three for two at 526.3 to 528 px).
  int fitting(double inner, double width) => _whole((inner + gap) / (width + gap));

  /// [x] rounded down to a whole number that is safe to count columns
  /// with: nothing for NaN and below zero, and no more than [_tooMany].
  /// (`floor()` on NaN or infinity throws.)
  static int _whole(double x) => x.isNaN || x <= 0 ? 0 : (x >= _tooMany ? _tooMany : x.floor());

  /// More columns than any screen has pixels.
  static const _tooMany = 1 << 20;

  /// How wide a tile is with [columns] of them a row: the size to keep.
  double tileWidth(double inner, int columns) => (inner - (columns - 1) * gap) / columns;

  /// A pinch is a step each time the fingers spread by a quarter (positive)
  /// or close by as much (negative). None for a scale that is no scale
  /// (zero, as two fingers on one spot give, below it or not a number):
  /// its logarithm could not be counted in steps.
  static int pinchSteps(double scale) =>
      scale.isFinite && scale > 0 ? (math.log(scale) / math.log(1.25)).truncate() : 0;
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

  /// Asked for another column count; the grid clamps it to what it allows
  /// and answers with the columns it has from now on, which [columns] only
  /// says after the grid is built again.
  final int Function(int columns) onColumns;

  /// Builds the grid with [physics]: null for its usual ones.
  final Widget Function(BuildContext context, ScrollPhysics? physics) builder;

  @override
  State<GridZoomArea> createState() => GridZoomAreaState();
}

class GridZoomAreaState extends State<GridZoomArea> {
  /// Ctrl is held: the wheel zooms, so the grid must not scroll with it.
  bool _ctrl = false;

  /// The fingers on the grid, in the order they came down. The first two
  /// pinch: [_pinchFrom] is how far apart they were, and [_pinchColumns]
  /// the columns then, at the last time the pinch started: a finger came
  /// or went, or the columns changed from outside ([_restartPinch]).
  final _fingers = <int, Offset>{};
  double? _pinchFrom;
  int _pinchColumns = 1;
  bool _pinched = false;

  /// The steps from [_pinchColumns] the pinch last asked for. The grid is
  /// only asked when the fingers reach another step, so a finger moving
  /// within a step leaves alone what a key or a button did meanwhile.
  int _pinchSteps = 0;

  /// A touchpad pinch reports its scale since it began: [_padScale] is
  /// the last one (null with no such pinch under way) and [_padFrom] the
  /// scale its steps are counted from, 1 until the pinch is started again.
  double? _padScale;
  double _padFrom = 1;

  /// What the grid answered the last time it was asked, until it is built
  /// again and [GridZoomArea.columns] says so itself. Several pointer
  /// events can come between two frames: a step, then a finger down. With
  /// the widget's count alone the second would start from the columns of
  /// before the step, and the next move would take the step back.
  int? _answered;

  /// The columns the grid has now, also between two frames.
  int get _columns => _answered ?? widget.columns;

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
  void didUpdateWidget(GridZoomArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built again: the widget's count is the grid's own once more. When it
    // is not what the area last knew, something else changed it (a key, a
    // button, a window resized), and a pinch under way goes on from it.
    final known = _answered ?? oldWidget.columns;
    _answered = null;
    if (widget.columns != known) _restartPinch();
  }

  /// The columns changed from outside with a pinch under way: it starts
  /// again from them and from where the fingers are now. Counted on from
  /// its old start, its next step would take a `+` typed meanwhile back,
  /// or bring the column count of before a resize to the new width.
  /// Nothing here is shown, so nothing is built again.
  void _restartPinch() {
    _pinchColumns = widget.columns;
    _pinchSteps = 0;
    if (_pinchFrom != null && _fingers.length >= 2) _pinchFrom = _spread;
    _padFrom = _padScale ?? 1;
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

  /// Asks the grid for [columns] and notes what it took.
  void _ask(int columns) {
    if (mounted) _answered = widget.onColumns(columns);
  }

  /// Bigger tiles (fewer columns) for [by] > 0, smaller for [by] < 0.
  void _step(int by) => _ask(_columns - by);

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
  /// Asked only when the step count changes: most moves stay within a
  /// step, and asking for the pinch's own columns again on each of them
  /// would undo a step made by a key since, which this area only learns
  /// of when it is built again ([didUpdateWidget]). (A pinch reaching a
  /// new step in the very frame of the key's step still counts from the
  /// columns of before the key: the area cannot know of it yet.)
  void _pinch(double scale) {
    final steps = GridZoom.pinchSteps(scale);
    if (steps == _pinchSteps) return;
    _pinchSteps = steps;
    _ask(_pinchColumns - steps);
  }

  /// A touchpad pinch begins, from the columns there are now.
  void _padStart() {
    if (!mounted) return;
    _pinchColumns = _columns;
    _pinchSteps = 0;
    _padScale = _padFrom = 1;
  }

  /// The touchpad pinch moved: its steps are counted from [_padFrom].
  void _padUpdate(PointerPanZoomUpdateEvent e) {
    _padScale = e.scale;
    _pinch(e.scale / _padFrom);
  }

  // The pointer callbacks below can still come after the grid is gone (a
  // tab change or a closed book with fingers down): the touch keeps
  // reporting to what it first hit. Then there is nothing to zoom.

  void _fingerDown(PointerDownEvent e) {
    if (!mounted) return;
    // A new touch or click: the last pinch is over.
    if (_fingers.isEmpty) _pinched = false;
    if (e.kind != PointerDeviceKind.touch) return;
    _fingers[e.pointer] = e.position;
    if (_fingers.length >= 2) _pinched = true;
    _rebase();
  }

  void _fingerMove(PointerMoveEvent e) {
    if (!mounted || !_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.position;
    final from = _pinchFrom;
    if (from != null && from > 0) _pinch(_spread / from);
  }

  void _fingerUp(PointerEvent e) {
    if (_fingers.remove(e.pointer) == null || !mounted) return;
    _rebase();
  }

  /// A finger came or went: the pinch starts again from the two fingers
  /// that are first now and the columns there are now. Without this, a
  /// third finger taking the place of one that lifted would be measured
  /// against the spread of the old pair, and the columns would jump. The
  /// columns are [_columns], right also when the finger comes in the same
  /// frame as a step.
  void _rebase() {
    final from = _fingers.length >= 2 ? _spread : null;
    _pinchColumns = _columns;
    _pinchSteps = 0;
    // The grid stops scrolling while two fingers are down, and scrolls
    // again when they are not.
    if ((from == null) != (_pinchFrom == null)) {
      setState(() => _pinchFrom = from);
    } else {
      _pinchFrom = from;
    }
  }

  /// How far apart the two pinching fingers are.
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
    onPointerPanZoomStart: (_) => _padStart(),
    onPointerPanZoomUpdate: _padUpdate,
    onPointerPanZoomEnd: (_) => _padScale = null,
    // Two fingers pinch; they do not scroll meanwhile. Nor does the wheel
    // while Ctrl makes it zoom.
    child: widget.builder(context, _pinchFrom != null || _ctrl ? const NeverScrollableScrollPhysics() : null),
  );
}
