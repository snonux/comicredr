import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:reader_input/reader_input.dart';

/// Touch input for the reader, the same on a Linux touchscreen as on the
/// phone. Taps, double-taps, long presses, swipes and two-finger taps become
/// [ReaderCommand]s handed to [onCommand], the same path keys take; what
/// each one does comes from the [TouchMap] (a preset picked in Settings,
/// with `keys.toml`'s `[touch]` lines over it). Pinch zoom and dragging are
/// left to the [InteractiveViewer] underneath, which gets every pointer as
/// well.
///
/// Taps, double-taps and long presses look up the 3x3 [TouchZone] they
/// land in. A tap only waits to see whether a second one follows in a zone
/// that has a double-tap action, so the edges turn pages at once. A swipe
/// that pans a zoomed page is a pan, not a swipe; in guided view, where one
/// finger doesn't pan, a swipe always counts.
///
/// Only fingers and pens count. A mouse click does nothing here, so clicking
/// the window to focus it never turns a page.
class ReaderTouch extends StatefulWidget {
  const ReaderTouch({
    super.key,
    required this.onCommand,
    required this.viewTransform,
    required this.guided,
    required this.touchMap,
    required this.child,
  });

  final ValueChanged<ReaderCommand> onCommand;

  /// The reader's current zoom and pan, or null with no page on screen.
  final ValueGetter<Matrix4?> viewTransform;

  /// Whether guided view is on.
  final ValueGetter<bool> guided;

  /// What each gesture does, read at the moment it happens.
  final ValueGetter<TouchMap> touchMap;
  final Widget child;

  /// A swipe this far across the view turns the page however slowly it
  /// moved; a quicker flick needs less.
  static const swipeDistance = 0.12;
  static const swipeVelocity = 400.0;

  @override
  State<ReaderTouch> createState() => _ReaderTouchState();
}

class _ReaderTouchState extends State<ReaderTouch> {
  /// Where each finger of this gesture came down.
  final _downAt = <int, Offset>{};

  /// More than one finger touched during this gesture: a pinch or a
  /// two-finger tap, not a tap or a swipe.
  bool _multi = false;

  /// Most fingers down at once in this gesture, and whether any of them
  /// moved beyond a tap.
  int _most = 0;
  bool _anyMoved = false;

  int? _primary;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  Duration _startTime = Duration.zero;
  Matrix4? _startTransform;
  VelocityTracker? _velocity;

  /// A long press waiting for its time, and whether it fired.
  Timer? _longPress;
  bool _longPressed = false;

  /// A tap waiting to see whether a second one follows.
  Timer? _pendingTap;
  Offset? _pendingTapAt;
  TouchZone? _pendingZone;

  @override
  void dispose() {
    _pendingTap?.cancel();
    _longPress?.cancel();
    super.dispose();
  }

  static bool _isTouch(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch ||
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  TouchZone? _zoneOf(Offset at) {
    final size = context.size;
    if (size == null || size.isEmpty) return null;
    return TouchZone.at(at.dx / size.width, at.dy / size.height);
  }

  void _onDown(PointerDownEvent e) {
    if (!_isTouch(e)) return;
    _downAt[e.pointer] = e.localPosition;
    _most = max(_most, _downAt.length);
    if (_downAt.length > 1) {
      _multi = true;
      _cancelLongPress();
      return;
    }
    _primary = e.pointer;
    _start = _last = e.localPosition;
    _startTime = e.timeStamp;
    _startTransform = widget.viewTransform();
    _velocity = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.localPosition);
    _longPressed = false;
    final zone = _zoneOf(e.localPosition);
    final intent = zone == null ? null : widget.touchMap().action(TouchGesture.longPress, zone);
    if (intent != null) {
      _longPress = Timer(kLongPressTimeout, () {
        _longPress = null;
        if (_multi || _primary == null || (_last - _start).distance >= kTouchSlop) return;
        _longPressed = true;
        _flushPendingTap();
        _send(ReaderCommand(intent, at: Point(_start.dx, _start.dy)));
      });
    }
  }

  void _onMove(PointerMoveEvent e) {
    final from = _downAt[e.pointer];
    if (from == null) return;
    if ((e.localPosition - from).distance >= kTouchSlop) _anyMoved = true;
    if (e.pointer != _primary) return;
    _last = e.localPosition;
    _velocity?.addPosition(e.timeStamp, e.localPosition);
    if ((_last - _start).distance >= kTouchSlop) _cancelLongPress();
  }

  void _onUp(PointerUpEvent e) {
    if (_downAt.remove(e.pointer) == null) return;
    if (e.pointer == _primary && !_multi) {
      _last = e.localPosition;
      _velocity?.addPosition(e.timeStamp, e.localPosition);
      _cancelLongPress();
      if (!_longPressed) _finish(e.timeStamp - _startTime);
    }
    if (_downAt.isEmpty && _multi && _most == 2 && !_anyMoved && e.timeStamp - _startTime < kLongPressTimeout) {
      _twoFingerTap();
    }
    _endIfDone();
  }

  void _onCancel(PointerCancelEvent e) {
    if (_downAt.remove(e.pointer) == null) return;
    _multi = true; // Whatever it was, it did not finish.
    _anyMoved = true;
    _cancelLongPress();
    _endIfDone();
  }

  void _endIfDone() {
    if (_downAt.isNotEmpty) return;
    _multi = false;
    _most = 0;
    _anyMoved = false;
    _primary = null;
    _velocity = null;
  }

  void _cancelLongPress() {
    _longPress?.cancel();
    _longPress = null;
  }

  void _finish(Duration held) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final moved = _last - _start;
    if (moved.distance < kTouchSlop && held < kLongPressTimeout) {
      _tap(_start);
      return;
    }
    final v = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    bool swiped(double d, double across, double speed, double extent) =>
        d.abs() > 2 * across.abs() &&
        (d.abs() > ReaderTouch.swipeDistance * extent ||
            (d.abs() > 2 * kTouchSlop && speed.abs() > ReaderTouch.swipeVelocity && speed.sign == d.sign));
    final TouchGesture swipe;
    if (swiped(moved.dx, moved.dy, v.dx, size.width)) {
      // Finger moving left drags the next page in, as `→` would.
      swipe = moved.dx < 0 ? TouchGesture.swipeLeft : TouchGesture.swipeRight;
    } else if (swiped(moved.dy, moved.dx, v.dy, size.height)) {
      swipe = moved.dy < 0 ? TouchGesture.swipeUp : TouchGesture.swipeDown;
    } else {
      return;
    }
    final horizontal = swipe == TouchGesture.swipeLeft || swipe == TouchGesture.swipeRight;
    if (!widget.guided() && _viewMoved(horizontal: horizontal)) return;
    final intent = widget.touchMap().action(swipe);
    if (intent != null) _send(ReaderCommand(intent));
  }

  /// Whether the drag panned or zoomed the page along the swipe. A swipe
  /// on a page that fits, or one pushing against the edge of a zoomed page,
  /// moves nothing and so counts as a swipe instead.
  bool _viewMoved({required bool horizontal}) {
    final before = _startTransform;
    final after = widget.viewTransform();
    if (before == null || after == null) return false;
    final a = before.getTranslation(), b = after.getTranslation();
    return (horizontal ? (a.x - b.x).abs() : (a.y - b.y).abs()) > 1 ||
        (before.getMaxScaleOnAxis() - after.getMaxScaleOnAxis()).abs() > 0.01;
  }

  void _tap(Offset at) {
    final zone = _zoneOf(at);
    if (zone == null) return;
    final map = widget.touchMap();
    final first = _pendingTapAt;
    if (first != null && _pendingZone == zone && (at - first).distance < kDoubleTapSlop) {
      _clearPendingTap();
      final intent = map.action(TouchGesture.doubleTap, zone);
      if (intent != null) _send(ReaderCommand(intent, at: Point(at.dx, at.dy)));
      return;
    }
    _flushPendingTap();
    if (!map.waitsForDoubleTap(zone)) {
      _tapAction(zone, at);
      return;
    }
    _pendingTapAt = at;
    _pendingZone = zone;
    _pendingTap = Timer(kDoubleTapTimeout, _flushPendingTap);
  }

  void _tapAction(TouchZone zone, Offset at) {
    final intent = widget.touchMap().action(TouchGesture.tap, zone);
    if (intent != null) _send(ReaderCommand(intent, at: Point(at.dx, at.dy)));
  }

  /// Acts on a tap still waiting for a second one: a tap somewhere else, or
  /// time running out, makes it a single tap after all.
  void _flushPendingTap() {
    final at = _pendingTapAt, zone = _pendingZone;
    _clearPendingTap();
    if (at != null && zone != null) _tapAction(zone, at);
  }

  void _clearPendingTap() {
    _pendingTap?.cancel();
    _pendingTap = null;
    _pendingTapAt = null;
    _pendingZone = null;
  }

  void _twoFingerTap() {
    // A pinch that zoomed is not a tap, however little the fingers moved.
    final before = _startTransform, after = widget.viewTransform();
    if (before != null && after != null && (before.getMaxScaleOnAxis() - after.getMaxScaleOnAxis()).abs() > 0.01) {
      return;
    }
    final intent = widget.touchMap().action(TouchGesture.twoFingerTap);
    if (intent == null) return;
    _flushPendingTap();
    _send(ReaderCommand(intent));
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
