import 'dart:async';

import 'package:flutter/material.dart';

/// The time, large, in the middle of the screen (`T`, or a long press in
/// the middle): shown for [shown], then faded out, or just gone with
/// reduced motion. Another [ClockFlashState.flash] while it shows starts
/// the time again. It takes no taps, and the system's 12 or 24 hour
/// setting decides the format.
class ClockFlash extends StatefulWidget {
  const ClockFlash({super.key, this.now = DateTime.now, this.shown = const Duration(seconds: 2)});

  /// The clock to read, for tests.
  final DateTime Function() now;
  final Duration shown;

  static const fade = Duration(milliseconds: 600);

  @override
  State<ClockFlash> createState() => ClockFlashState();
}

class ClockFlashState extends State<ClockFlash> {
  Timer? _hide;
  bool _visible = false;

  /// Whether anything is drawn: while shown and while fading.
  bool _built = false;

  void flash() {
    _hide?.cancel();
    setState(() => _visible = _built = true);
    _hide = Timer(widget.shown, () {
      if (!mounted) return;
      final still = MediaQuery.disableAnimationsOf(context);
      setState(() {
        _visible = false;
        if (still) _built = false;
      });
      if (still) return;
      _hide = Timer(ClockFlash.fade, () {
        if (mounted) setState(() => _built = false);
      });
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_built) return const SizedBox.shrink();
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(widget.now()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final small = MediaQuery.sizeOf(context).shortestSide < 600;
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: _visible || MediaQuery.disableAnimationsOf(context) ? Duration.zero : ClockFlash.fade,
          // A dim backing and soft light letters: readable over any page,
          // and not a flash of white in a dark room.
          child: Container(
            key: const Key('clock'),
            padding: EdgeInsets.symmetric(horizontal: small ? 28 : 44, vertical: small ? 12 : 18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(small ? 20 : 28),
            ),
            child: Semantics(
              liveRegion: true,
              child: Text(
                time,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: small ? 64 : 112,
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
