import 'dart:async';

import 'package:flutter/material.dart';

/// The time in a corner of the reader (`T`): small, faint and out of the
/// way of taps. The system's 12 or 24 hour setting decides the format. It
/// redraws on the minute, and nothing else ticks.
class ReaderClock extends StatefulWidget {
  const ReaderClock({super.key, this.now = DateTime.now});

  /// The clock to read, for tests.
  final DateTime Function() now;

  @override
  State<ReaderClock> createState() => _ReaderClockState();
}

class _ReaderClockState extends State<ReaderClock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Wakes a moment after the next minute starts.
  void _schedule() {
    final now = widget.now();
    final wait = Duration(seconds: 60 - now.second, milliseconds: 50 - now.millisecond);
    _tick = Timer(wait, () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(widget.now()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    // Light letters with a dark halo read on white paper and black pages
    // alike, and let the art show through.
    return IgnorePointer(
      child: Text(
        time,
        key: const Key('clock'),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
          // A thin dark outline, crisp on white paper, and a soft halo.
          shadows: [
            for (final (dx, dy) in const [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)])
              Shadow(color: Colors.black.withValues(alpha: 0.5), offset: Offset(dx, dy), blurRadius: 0.5),
            Shadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4),
          ],
        ),
      ),
    );
  }
}
