import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'data/data_dirs.dart';

/// How long the steps a reader waits on take, for measuring the app's speed
/// (`tool/e2e/e2e_perf.sh`). With `COMICREDR_TIMING=1` in the environment, or
/// on Android built with `--dart-define=COMICREDR_TIMING=true` (an app has
/// no environment of its own there; the lines go to `adb logcat`), each step
/// prints a line `timing: <what> <ms> ms` on standard output, and frames are
/// summed up every two seconds they are drawn; without it nothing is
/// measured.
final timingOn = const bool.fromEnvironment('COMICREDR_TIMING') || appEnvironment['COMICREDR_TIMING'] == '1';

/// When the app's `main` started; the start-up steps are counted from here.
final appClock = Stopwatch()..start();

/// Prints how long [what] took on [watch], when timing is on.
void timing(String what, Stopwatch watch) {
  if (timingOn) debugPrint('timing: $what ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms');
}

/// Times [work] as [what].
Future<T> timed<T>(String what, Future<T> Function() work) async {
  if (!timingOn) return work();
  final watch = Stopwatch()..start();
  try {
    return await work();
  } finally {
    timing(what, watch);
  }
}

/// Starts summing up frames: every two seconds that had frames, how many,
/// and the median, 90th percentile and slowest of their build (UI thread)
/// and raster times, and how many missed 16.7 ms.
void timeFrames() {
  if (!timingOn) return;
  final frames = <FrameTiming>[];
  var since = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((batch) {
    frames.addAll(batch);
    if (DateTime.now().difference(since) < const Duration(seconds: 2)) return;
    since = DateTime.now();
    final build = [for (final f in frames) f.buildDuration.inMicroseconds / 1000]..sort();
    final raster = [for (final f in frames) f.rasterDuration.inMicroseconds / 1000]..sort();
    final slow = frames.where((f) => f.totalSpan.inMicroseconds > 16667).length;
    String sum(List<double> v) =>
        '${v[v.length ~/ 2].toStringAsFixed(1)}/${v[(v.length * 9) ~/ 10].toStringAsFixed(1)}/'
        '${v.last.toStringAsFixed(1)}';
    debugPrint('timing: frames ${frames.length} build ${sum(build)} raster ${sum(raster)} ms slow $slow');
    frames.clear();
  });
}
