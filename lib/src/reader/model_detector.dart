import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// The file name the app looks for in its models folder.
const modelFileName = 'comicredr-panels.onnx';

/// The model's square input side in pixels (spike/export_onnx.py --imgsz).
const modelInputSize = 800;

/// Where the installed model is, or null to use classic CV.
///
/// `COMICREDR_MODEL` names a file directly (the end-to-end test uses it).
/// Otherwise the app looks for [modelFileName] in a `models` folder in its
/// data directory: `~/.local/share/org.snonux.comicredr/models/` on Fedora,
/// and on Android the app's folder on shared storage,
/// `Android/data/org.snonux.comicredr/files/models/`, which `adb push`
/// and a file manager can both reach. The model is not in the repository
/// or the app bundle; see the README.
Future<String?> findModel() async {
  final named = Platform.environment['COMICREDR_MODEL'];
  if (named != null && named.isNotEmpty) return File(named).existsSync() ? named : null;
  final dirs = <Future<Directory?> Function()>[
    getApplicationSupportDirectory,
    if (Platform.isAndroid) getExternalStorageDirectory,
  ];
  for (final dir in dirs) {
    try {
      final d = await dir();
      final f = File('${d?.path}/models/$modelFileName');
      if (d != null && f.existsSync()) return f.path;
    } catch (_) {
      // No plugin (tests) or no such directory: keep looking, then give up.
    }
  }
  return null;
}

/// The trained panel and balloon detector (design plan section 9), run by
/// ONNX Runtime on the CPU in a long-lived worker isolate.
///
/// ONNX Runtime is reached through `dart:ffi`, so inference runs on the
/// worker's own thread plus the runtime's thread pool. The UI isolate and
/// the platform thread never wait on it, so a page turn can't stutter
/// behind a detection. The session loads once, on the first page.
class ModelDetector {
  ModelDetector(this.path, {this.inputSize = modelInputSize, int? threads})
    : threads = threads ?? (Platform.numberOfProcessors - 2).clamp(1, 8);

  /// The .onnx file.
  final String path;
  final int inputSize;

  /// ONNX Runtime's intra-op threads: all cores but two, so reading stays
  /// smooth while pages are analysed (design plan section 9).
  final int threads;

  Future<SendPort>? _worker;
  int _next = 0;
  final _pending = <int, Completer<ModelDetection>>{};
  Completer<void>? _closed;
  bool _closing = false;

  /// Runs the model on an RGBA page of [w] x [h], its long side at most
  /// [inputSize]. Returns frames in reading order and balloons.
  Future<ModelDetection> detect(Uint8List rgba, int w, int h) async {
    if (_closing) throw StateError('The model detector is closed');
    final port = await (_worker ??= _spawn());
    final id = _next++;
    final done = Completer<ModelDetection>();
    _pending[id] = done;
    port.send((id, TransferableTypedData.fromList([rgba]), w, h));
    return done.future;
  }

  Future<SendPort> _spawn() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    replies.listen((Object? msg) {
      switch (msg) {
        case SendPort port:
          ready.complete(port);
        case (int id, List<double> frames, List<double> balloons):
          _pending
              .remove(id)
              ?.complete(ModelDetection(_panels(frames, PanelKind.frame), _panels(balloons, PanelKind.balloon)));
        case (int id, String error):
          _pending.remove(id)?.completeError(StateError(error));
        case 'closed':
          _closed?.complete();
          replies.close();
        case (String error,):
          // The session could not load: fail everything, now and later.
          if (!ready.isCompleted) ready.completeError(StateError(error));
          for (final c in _pending.values) {
            c.completeError(StateError(error));
          }
          _pending.clear();
      }
    });
    await Isolate.spawn(_serve, (replies.sendPort, path, inputSize, threads), debugName: 'model-detector');
    return ready.future;
  }

  /// Lets the page being detected finish, then releases the session and
  /// ONNX Runtime, before the app exits.
  ///
  /// Left running, the runtime's thread pool can still be inside a
  /// detection while the process tears its native libraries down, and the
  /// app crashes on its way out. Waits at most [timeout].
  Future<void> close({Duration timeout = const Duration(seconds: 3)}) async {
    if (_closing) return _closed?.future ?? Future.value();
    _closing = true;
    final worker = _worker;
    if (worker == null) return;
    final SendPort port;
    try {
      port = await worker;
    } catch (_) {
      return; // The session never loaded, so there is nothing to release.
    }
    final closed = _closed = Completer<void>();
    port.send('close');
    await closed.future.timeout(timeout, onTimeout: () => debugPrint('The model detector did not close in time'));
  }
}

/// Panels travel between isolates as flat x, y, w, h, confidence rows.
List<Panel> _panels(List<double> flat, PanelKind kind) => [
  for (var i = 0; i + 4 < flat.length; i += 5)
    Panel(flat[i], flat[i + 1], flat[i + 2], flat[i + 3], kind: kind, confidence: flat[i + 4]),
];

List<double> _flat(List<Panel> panels) => [
  for (final p in panels) ...[p.x, p.y, p.w, p.h, p.confidence],
];

/// The worker: owns the ONNX Runtime session for the app's lifetime.
Future<void> _serve((SendPort, String, int, int) args) async {
  final (reply, path, size, threads) = args;
  final OrtSession session;
  try {
    OrtEnv.instance.init();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(threads)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    session = OrtSession.fromFile(File(path), options);
  } catch (e) {
    reply.send(('Could not load $path: $e',));
    return;
  }
  final requests = ReceivePort();
  reply.send(requests.sendPort);
  final input = session.inputNames.first;
  await for (final msg in requests) {
    if (msg == 'close') {
      // Requests are served in order, so none is still running here.
      session.release();
      OrtEnv.instance.release();
      requests.close();
      reply.send('closed');
      return;
    }
    final (int id, TransferableTypedData data, int w, int h) = msg as (int, TransferableTypedData, int, int);
    OrtValueTensor? tensor;
    OrtRunOptions? run;
    List<OrtValue?> outputs = const [];
    try {
      final rgba = data.materialize().asUint8List();
      tensor = OrtValueTensor.createTensorWithDataList([letterboxTensor(rgba, w, h, size)], [1, 3, size, size]);
      run = OrtRunOptions();
      outputs = session.run(run, {input: tensor});
      final rows = [
        for (final row in (outputs.first!.value as List).first as List)
          for (final v in row as List) (v as num).toDouble(),
      ];
      final found = decodeDetections(rows, w, h);
      reply.send((id, _flat(found.frames), _flat(found.balloons)));
    } catch (e) {
      reply.send((id, '$e'));
    } finally {
      tensor?.release();
      run?.release();
      for (final o in outputs) {
        o?.release();
      }
    }
  }
}
