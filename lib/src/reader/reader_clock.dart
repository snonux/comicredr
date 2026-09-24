import 'dart:async';

import 'package:flutter/material.dart';

/// The time on the reader's status line (`T`). The system's 12 or 24 hour
/// setting decides the format. It redraws on the minute, and nothing else
/// ticks.
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
  Widget build(BuildContext context) => Text(
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(widget.now()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    ),
    key: const Key('clock'),
    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
  );
}
