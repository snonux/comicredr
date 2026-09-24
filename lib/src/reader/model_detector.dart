import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';
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
  ModelDetector(this.path, {required this.version, this.inputSize = modelInputSize, int? threads})
    : threads = threads ?? (Platform.numberOfProcessors - 2).clamp(1, 8);

  /// Loads the detector for the model at [path], hashing the file off the
  /// UI isolate for its [version].
  static Future<ModelDetector> open(String path) async {
    final version = await Isolate.run(() => modelVersion(File(path).readAsBytesSync()));
    return ModelDetector(path, version: version);
  }

  /// The .onnx file.
  final String path;

  /// What panels found with this model file are cached under (see
  /// [modelVersion]).
  final int version;
  final int inputSize;

  /// ONNX Runtime's intra-op threads: all cores but two, so reading stays
  /// smooth while pages are analysed (design plan section 9).
  final int threads;

  Future<SendPort>? _worker;
  int _next = 0;
  final _pending = <int, Completer<ModelDetection>>{};

  /// Runs the model on an RGBA page of [w] x [h], its long side at most
  /// [inputSize]. Returns frames in reading order, with their outlines where
  /// they are not rectangles (refineOutlines), and balloons.
  Future<ModelDetection> detect(Uint8List rgba, int w, int h) async {
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
        case (int id, List<double> frames, List<List<double>?> shapes, List<double> balloons):
          _pending
              .remove(id)
              ?.complete(
                ModelDetection([
                  for (final (i, f) in _panels(frames, PanelKind.frame).indexed) f.withShape(shapes[i]),
                ], _panels(balloons, PanelKind.balloon)),
              );
        case (int id, String error):
          _pending.remove(id)?.completeError(StateError(error));
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
}

/// Panels travel between isolates as flat x, y, w, h, confidence rows, and
/// frame outlines beside them.
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
      // The page is already here at the model's size: find the real outline
      // of slanted and cut frames while at it.
      final frames = refineOutlines(rgba, w, h, found.frames, found.balloons);
      reply.send((id, _flat(frames), [for (final f in frames) f.shape], _flat(found.balloons)));
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
