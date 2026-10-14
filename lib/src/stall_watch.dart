import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Says on stderr whenever the app stops answering for a while, for a
/// freeze that cannot be reproduced on demand: `COMICREDR_STALLS=1
/// comicredr 2> stalls.log`. Two things are watched. The UI isolate's
/// event loop: a timer that should fire every [tick] and fires late was
/// held up by work on the UI isolate. And frames: one that took longer
/// than [slowFrame] to build or to draw. A window whose GTK thread hangs
/// (a platform call that does not return) shows neither; it is seen as
/// frames that stop coming while the event loop runs on, and the platform
/// calls named in the log just before it are the suspects.
class StallWatch {
  StallWatch({this.tick = const Duration(milliseconds: 100), this.threshold = const Duration(milliseconds: 400)});

  final Duration tick;
  final Duration threshold;
  static const slowFrame = Duration(milliseconds: 250);

  Timer? _timer;
  final _clock = Stopwatch();

  void start() {
    _clock.start();
    var last = _clock.elapsed;
    _timer = Timer.periodic(tick, (_) {
      final now = _clock.elapsed;
      final late = now - last - tick;
      last = now;
      if (late >= threshold) say('UI isolate blocked for ${late.inMilliseconds} ms');
    });
    SchedulerBinding.instance.addTimingsCallback(_frames);
  }

  void _frames(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      if (t.buildDuration >= slowFrame || t.rasterDuration >= slowFrame) {
        say('Slow frame: build ${t.buildDuration.inMilliseconds} ms, raster ${t.rasterDuration.inMilliseconds} ms');
      }
    }
  }

  void stop() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_frames);
  }

  /// One line with the time, so it can be lined up with what was done.
  static void say(String what) => debugPrint('[stall ${DateTime.now().toIso8601String()}] $what');
}
