import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import '../data/data_dirs.dart';

/// The file name the app looks for in its models folder.
const modelFileName = 'comicredr-panels.onnx';

/// The model's square input side in pixels (spike/export_onnx.py --imgsz).
const modelInputSize = 800;

/// Where the model the app detects with is, or null to use classic CV.
///
/// `COMICREDR_MODEL` names a file directly (the end-to-end tests use it);
/// `COMICREDR_MODEL=none` forces classic CV. Otherwise a model the user
/// installed wins: [modelFileName] in a `models` folder in the app's data
/// directory ([appDirs]: `~/Comics/.comicredr/models/` or
/// `~/.local/share/org.snonux.comicredr/models/` on Fedora, the latter
/// looked at either way), and on Android also the app's folder on shared storage,
/// `Android/data/org.snonux.comicredr/files/models/`, which `adb push` can
/// reach. Last comes the model built into the app (see [bundledModel]).
Future<String?> findModel() async {
  final named = Platform.environment['COMICREDR_MODEL'];
  if (named == 'none') return null;
  if (named != null && named.isNotEmpty) return File(named).existsSync() ? named : null;
  final dirs = <Future<Directory?> Function()>[
    appDataDirectory,
    if (!Platform.isAndroid) () async => switch (xdgDataFolder()) {
      final d? => Directory(d),
      null => null,
    },
    if (Platform.isAndroid) getExternalStorageDirectory,
  ];
  for (final dir in dirs) {
    try {
      final d = await dir();
      final f = File('${d?.path}/models/$modelFileName');
      if (d != null && f.existsSync()) return f.path;
    } catch (_) {
      // No plugin (tests) or no such directory: keep looking.
    }
  }
  return bundledModel();
}

/// The asset key of the model the build packs into the app.
const bundledModelAsset = 'assets/models/$modelFileName';

/// The model built into the app, or null when it was built without one.
///
/// On the desktop Flutter's assets are plain files beside the executable,
/// so ONNX Runtime opens the bundled file where it is. On Android they are
/// inside the APK: the model is copied out once into the app's private
/// data folder, and again only when an update brings a different model.
Future<String?> bundledModel() async {
  try {
    if (!Platform.isAndroid) {
      final exe = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exe/data/flutter_assets/$bundledModelAsset');
      return f.existsSync() ? f.path : null;
    }
    final bytes = (await rootBundle.load(bundledModelAsset)).buffer.asUint8List();
    final dir = Directory('${(await appDataDirectory()).path}/bundled-model');
    return await Isolate.run(() => extractModel(bytes, dir.path));
  } catch (_) {
    // No asset (built without the model) or no data folder.
    return null;
  }
}

/// Writes [bytes] to [dir] unless the copy there is already this model,
/// and returns the file.
@visibleForTesting
String extractModel(Uint8List bytes, String dir) {
  final f = File('$dir/$modelFileName');
  final stamp = File('$dir/$modelFileName.version');
  final version = '${modelVersion(bytes)}';
  if (!f.existsSync() || f.lengthSync() != bytes.length || !stamp.existsSync() || stamp.readAsStringSync() != version) {
    Directory(dir).createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(f.path);
    stamp.writeAsStringSync(version);
  }
  return f.path;
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
      // of slanted and cut frames while at it, then sort again, since panels
      // either side of a slanted gutter read by their outlines.
      final frames = readingOrder(refineOutlines(rgba, w, h, found.frames, found.balloons), aspect: w / h);
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
