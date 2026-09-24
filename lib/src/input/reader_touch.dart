import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:reader_input/reader_input.dart';

/// Touch input for the reader, the same on a Linux touchscreen as on the
/// phone. Taps and swipes become [ReaderCommand]s handed to [onCommand], the
/// same path keys take; pinch zoom and dragging are left to the
/// [InteractiveViewer] underneath, which gets every pointer as well.
///
/// - Tap the left or right edge: previous or next step (a panel in guided
///   view, a page otherwise), like `←` and `→`.
/// - Swipe left or right: next or previous step, unless the swipe panned a
///   zoomed page instead. In guided view a swipe always steps: the camera
///   is always zoomed there, and it glides on to the next panel from
///   wherever the finger left it.
/// - Tap the middle: status line on or off. Double-tap the middle: zoom in
///   on that spot, or back out when zoomed; in guided view, re-centre the
///   panel.
///
/// Only fingers and pens count. A mouse click does nothing here, so clicking
/// the window to focus it never turns a page.
class ReaderTouch extends StatefulWidget {
  const ReaderTouch({
    super.key,
    required this.onCommand,
    required this.viewTransform,
    required this.guided,
    required this.child,
  });

  final ValueChanged<ReaderCommand> onCommand;

  /// The reader's current zoom and pan, or null with no page on screen.
  final ValueGetter<Matrix4?> viewTransform;

  /// Whether guided view is on.
  final ValueGetter<bool> guided;
  final Widget child;

  /// Width of each edge zone that turns pages, as a share of the view.
  static const edge = 0.3;

  /// A swipe this far across the view turns the page however slowly it
  /// moved; a quicker flick needs less.
  static const swipeDistance = 0.12;
  static const swipeVelocity = 400.0;

  /// Double-tap zoom: 1.25^4, about 2.4x.
  static const doubleTapZoomSteps = 4;

  @override
  State<ReaderTouch> createState() => _ReaderTouchState();
}

class _ReaderTouchState extends State<ReaderTouch> {
  final _down = <int>{};

  /// More than one finger touched during this gesture: a pinch, not a tap.
  bool _multi = false;

  int? _primary;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  Duration _startTime = Duration.zero;
  Matrix4? _startTransform;
  VelocityTracker? _velocity;

  /// A middle tap waiting to see whether a second one follows.
  Timer? _pendingTap;
  Offset? _pendingTapAt;

  @override
  void dispose() {
    _pendingTap?.cancel();
    super.dispose();
  }

  static bool _isTouch(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch ||
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  void _onDown(PointerDownEvent e) {
    if (!_isTouch(e)) return;
    _down.add(e.pointer);
    if (_down.length > 1) {
      _multi = true;
      return;
    }
    _primary = e.pointer;
    _start = _last = e.localPosition;
    _startTime = e.timeStamp;
    _startTransform = widget.viewTransform();
    _velocity = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.localPosition);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _primary) return;
    _last = e.localPosition;
    _velocity?.addPosition(e.timeStamp, e.localPosition);
  }

  void _onUp(PointerUpEvent e) {
    if (!_down.remove(e.pointer)) return;
    if (e.pointer == _primary && !_multi) {
      _last = e.localPosition;
      _velocity?.addPosition(e.timeStamp, e.localPosition);
      _finish(e.timeStamp - _startTime);
    }
    _endIfDone();
  }

  void _onCancel(PointerCancelEvent e) {
    if (!_down.remove(e.pointer)) return;
    _multi = true; // Whatever it was, it did not finish.
    _endIfDone();
  }

  void _endIfDone() {
    if (_down.isNotEmpty) return;
    _multi = false;
    _primary = null;
    _velocity = null;
  }

  void _finish(Duration held) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final moved = _last - _start;
    if (moved.distance < kTouchSlop && held < kLongPressTimeout) {
      _tap(_start, size);
      return;
    }
    final vx = _velocity?.getVelocity().pixelsPerSecond.dx ?? 0;
    final horizontal = moved.dx.abs() > 2 * moved.dy.abs();
    final far = moved.dx.abs() > ReaderTouch.swipeDistance * size.width;
    final quick = moved.dx.abs() > 2 * kTouchSlop && vx.abs() > ReaderTouch.swipeVelocity && vx.sign == moved.dx.sign;
    if (horizontal && (far || quick) && (widget.guided() || !_viewMoved())) {
      // Finger moving left drags the next page in, as `→` would.
      _send(ReaderCommand(moved.dx < 0 ? ReaderIntent.nextStep : ReaderIntent.prevStep));
    }
  }

  /// Whether the drag panned or zoomed the page sideways. A swipe on a page
  /// that fits, or one pushing against the edge of a zoomed page, moves
  /// nothing and so turns the page instead.
  bool _viewMoved() {
    final before = _startTransform;
    final after = widget.viewTransform();
    if (before == null || after == null) return false;
    return (before.getTranslation().x - after.getTranslation().x).abs() > 1 ||
        (before.getMaxScaleOnAxis() - after.getMaxScaleOnAxis()).abs() > 0.01;
  }

  void _tap(Offset at, Size size) {
    if (at.dx < ReaderTouch.edge * size.width) {
      _clearPendingTap();
      _send(const ReaderCommand(ReaderIntent.prevStep));
      return;
    }
    if (at.dx > (1 - ReaderTouch.edge) * size.width) {
      _clearPendingTap();
      _send(const ReaderCommand(ReaderIntent.nextStep));
      return;
    }
    final first = _pendingTapAt;
    if (first != null && (at - first).distance < kDoubleTapSlop) {
      _clearPendingTap();
      _doubleTap(at);
      return;
    }
    _clearPendingTap();
    _pendingTapAt = at;
    _pendingTap = Timer(kDoubleTapTimeout, () {
      _pendingTapAt = null;
      _send(const ReaderCommand(ReaderIntent.fullscreen));
    });
  }

  void _clearPendingTap() {
    _pendingTap?.cancel();
    _pendingTap = null;
    _pendingTapAt = null;
  }

  void _doubleTap(Offset at) {
    final scale = widget.viewTransform()?.getMaxScaleOnAxis() ?? 1;
    _send(
      scale > 1.01
          ? const ReaderCommand(ReaderIntent.zoomReset)
          : ReaderCommand(ReaderIntent.zoomIn, count: ReaderTouch.doubleTapZoomSteps, at: Point(at.dx, at.dy)),
    );
  }

  void _send(ReaderCommand c) {
    if (mounted) widget.onCommand(c);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: _onUp,
    onPointerCancel: _onCancel,
    child: widget.child,
  );
}
