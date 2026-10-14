import 'dart:io';
import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart' show modelVersion;
import 'package:comicredr/src/reader/model_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bundled-model'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('copies the bundled model out once, and again when it changes', () {
    final dir = '${tmp.path}/bundled-model';
    final path = extractModel(Uint8List.fromList([1, 2, 3]), dir);
    expect(path, '$dir/$modelFileName');
    expect(File(path).readAsBytesSync(), [1, 2, 3]);

    final written = File(path).lastModifiedSync();
    File(path).setLastModifiedSync(written.subtract(const Duration(hours: 1)));
    extractModel(Uint8List.fromList([1, 2, 3]), dir);
    expect(File(path).lastModifiedSync().isBefore(written), isTrue, reason: 'same model, not rewritten');

    extractModel(Uint8List.fromList([4, 5, 6]), dir);
    expect(File(path).readAsBytesSync(), [4, 5, 6]);
  });

  test('takes the copy as it is until another install', () {
    final dir = '${tmp.path}/bundled-model';
    expect(keptModel(dir, 1000), isNull, reason: 'nothing copied yet');
    final path = extractModel(Uint8List.fromList([1, 2, 3]), dir, installed: 1000);
    expect(keptModel(dir, 1000), path);
    expect(keptModel(dir, 2000), isNull, reason: 'an update may bring another model');
    expect(keptModel(dir, null), isNull);

    extractModel(Uint8List.fromList([4, 5, 6]), dir, installed: 2000);
    expect(keptModel(dir, 2000), path);
    expect(File(path).readAsBytesSync(), [4, 5, 6]);
    extractModel(Uint8List.fromList([4, 5, 6]), dir);
    expect(keptModel(dir, 2000), isNull, reason: 'copied without knowing the install');
  });

  test('keeps the model version and hashes again when the file changes', () {
    final model = File('${tmp.path}/m.onnx')..writeAsBytesSync([1, 2, 3]);
    final cache = '${tmp.path}/cache/m.version';
    expect(cachedModelVersion(model.path, cache), modelVersion([1, 2, 3]));
    expect(File(cache).existsSync(), isTrue);

    // A kept version is read, not hashed: a planted one comes back.
    final lines = File(cache).readAsLinesSync();
    File(cache).writeAsStringSync([...lines.take(3), '42'].join('\n'));
    expect(cachedModelVersion(model.path, cache), 42);

    // Another model at the same path is hashed again.
    model.writeAsBytesSync([4, 5, 6, 7]);
    expect(cachedModelVersion(model.path, cache), modelVersion([4, 5, 6, 7]));
    File(cache).writeAsStringSync('broken');
    expect(cachedModelVersion(model.path, cache), modelVersion([4, 5, 6, 7]));
  });
}
