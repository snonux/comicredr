import 'dart:io';

import 'package:comicredr/src/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final name = line.substring('version:'.length).trim().split('+').first;
    expect(appVersion, name);
  });
}
