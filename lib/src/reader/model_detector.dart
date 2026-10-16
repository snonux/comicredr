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

/// The model's square input side in pixels (the input of detector/train.py --export).
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
    if (!Platform.isAndroid)
      () async => switch (xdgDataFolder()) {
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
/// Until the APK is updated the copy is taken as it is: reading the 40 MB
/// out of the APK and hashing them at every start held up the first comic.
Future<String?> bundledModel() async {
  try {
    if (!Platform.isAndroid) {
      final exe = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exe/data/flutter_assets/$bundledModelAsset');
      return f.existsSync() ? f.path : null;
    }
    final dir = '${(await appDataDirectory()).path}/bundled-model';
    final installed = await _android.invokeMethod<int>('installedAt').catchError((Object _) => null);
    if (keptModel(dir, installed) case final kept?) return kept;
    final bytes = (await rootBundle.load(bundledModelAsset)).buffer.asUint8List();
    return await Isolate.run(() => extractModel(bytes, dir, installed: installed));
  } catch (_) {
    // No asset (built without the model) or no data folder.
    return null;
  }
}

const _android = MethodChannel('org.snonux.comicredr/storage');

/// The model copied out into [dir] by the APK installed at [installed], or
/// null when it was copied by another install, or not at all.
@visibleForTesting
String? keptModel(String dir, int? installed) {
  final f = File('$dir/$modelFileName');
  final stamp = File('$dir/$modelFileName.installed');
  if (installed == null || !f.existsSync() || !stamp.existsSync()) return null;
  return stamp.readAsStringSync() == '$installed' ? f.path : null;
}

/// Writes [bytes] to [dir] unless the copy there is already this model,
/// and returns the file. [installed], when known, is noted for [keptModel].
@visibleForTesting
String extractModel(Uint8List bytes, String dir, {int? installed}) {
  final f = File('$dir/$modelFileName');
  final stamp = File('$dir/$modelFileName.version');
  final version = '${modelVersion(bytes)}';
  if (!f.existsSync() || f.lengthSync() != bytes.length || !stamp.existsSync() || stamp.readAsStringSync() != version) {
    Directory(dir).createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(f.path);
    stamp.writeAsStringSync(version);
  }
  final kept = File('$dir/$modelFileName.installed');
  if (installed != null) {
    kept.writeAsStringSync('$installed');
  } else if (kept.existsSync()) {
    kept.deleteSync();
  }
  return f.path;
}

/// [modelVersion] of the model file at [path]. Hashing its 40 MB took some
/// 0.2 s at every start before the first comic could open, so the result
/// is kept in the file [cache] with the model's path, size and time, and
/// read from there while they match. Runs on a worker isolate.
@visibleForTesting
int cachedModelVersion(String path, String cache) {
  final model = File(path).statSync();
  final stamp = '$path\n${model.size}\n${model.modified.microsecondsSinceEpoch}';
  final file = File(cache);
  try {
    final lines = file.readAsLinesSync();
    if (lines.length == 4 && lines.take(3).join('\n') == stamp) return int.parse(lines[3]);
  } catch (_) {
    // Not kept yet, or a broken file: hash.
  }
  final version = modelVersion(File(path).readAsBytesSync());
  try {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$stamp\n$version');
  } catch (_) {
    // Kept or not, the version is right.
  }
  return version;
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
  /// UI isolate for its [version], or reading it from where the hash was
  /// kept last time ([cachedModelVersion]).
  static Future<ModelDetector> open(String path) async {
    String? cache;
    try {
      cache = '${(await appDirs()).cache}/$modelFileName.version';
    } catch (_) {
      // No cache folder (tests): hash every time.
    }
    final version = await Isolate.run(
      () => cache == null ? modelVersion(File(path).readAsBytesSync()) : cachedModelVersion(path, cache),
    );
    return ModelDetector(path, version: version);
  }

  /// Starts the worker and loads the model (some 0.4 s on a laptop) unless
  /// that has been done, so it can go on while the first page decodes. A
  /// model that fails to load fails the next [detect], as it would anyway.
  void warm() => unawaited((_worker ??= _spawn()).then((_) {}, onError: (Object _) {}));

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
    var started = false;
    replies.listen((Object? msg) {
      switch (msg) {
        case final SendPort port:
          started = true;
          ready.complete(port);
        case (final int id, final List<double> frames, final List<List<double>?> shapes, final List<double> balloons):
          _pending
              .remove(id)
              ?.complete(
                ModelDetection([
                  for (final (i, f) in _panels(frames, PanelKind.frame).indexed) f.withShape(shapes[i]),
                ], _panels(balloons, PanelKind.balloon)),
              );
        case (final int id, final String error):
          _pending.remove(id)?.completeError(StateError(error));
        case (final String error,):
          // The session could not load: fail everything, now and later.
          if (!ready.isCompleted) ready.completeError(StateError(error));
          _failPending(error);
      }
    });
    // A worker that dies (an uncaught error, killed) fails what it was asked
    // and is started again on the next page, rather than leaving every
    // detection waiting for good. One that exits before it was ready
    // failed to load, and already said why.
    final exits = ReceivePort();
    exits.listen((Object? msg) {
      exits.close();
      replies.close();
      final why = msg is List && msg.isNotEmpty ? 'The detector stopped: ${msg.first}' : 'The detector stopped';
      if (!ready.isCompleted) ready.completeError(StateError(why));
      // A model that would not load stays failed; only a running one restarts.
      if (started) _worker = null;
      _failPending(why);
    });
    try {
      await Isolate.spawn(
        _serve,
        (replies.sendPort, path, inputSize, threads),
        debugName: 'model-detector',
        onExit: exits.sendPort,
        onError: exits.sendPort,
      );
    } on Object {
      exits.close();
      replies.close();
      _worker = null;
      rethrow;
    }
    return ready.future;
  }

  void _failPending(String error) {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final c in waiting) {
      c.completeError(StateError(error));
    }
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
