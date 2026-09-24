// Runs the classic-CV detector over greyscale PGM files and prints one JSON
// line per page. Used to check the Dart port against spike/detect_cv.py:
//
//   dart run tool/detect_pgm.dart page1.pgm page2.pgm ...
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';

GrayImage readPgm(String path) {
  final b = File(path).readAsBytesSync();
  var i = 0;
  String token() {
    while (b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09) {
      i++;
    }
    final s = i;
    while (!(b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09)) {
      i++;
    }
    return String.fromCharCodes(b.sublist(s, i));
  }

  if (token() != 'P5') throw FormatException('not a binary PGM: $path');
  final w = int.parse(token()), h = int.parse(token());
  token(); // maxval
  i++;
  return GrayImage(w, h, Uint8List.sublistView(b, i, i + w * h));
}

void main(List<String> args) {
  for (final path in args) {
    final img = readPgm(path);
    final sw = Stopwatch()..start();
    final d = detectPanels(img);
    stdout.writeln(
      jsonEncode({
        'path': path,
        'ms': sw.elapsedMilliseconds,
        'passed': d.gate.passed,
        'reasons': d.gate.reasons,
        'panels': [
          for (final p in d.frames) [p.x, p.y, p.w, p.h],
        ],
      }),
    );
  }
}
