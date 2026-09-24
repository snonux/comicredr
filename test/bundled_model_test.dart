import 'dart:io';
import 'dart:typed_data';

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

}
