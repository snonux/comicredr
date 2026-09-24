// Scan clean-up (`c`) on one page, outside the app, to look at and time:
//   dart run tool/cleanup_ppm.dart page.ppm out.ppm [scale]
// Reads and writes binary PPM (P6). Prints the levels found on a 240 px
// copy, as the app measures them, and how long each step took.
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: cleanup_ppm.dart in.ppm out.ppm [scale]');
    exit(64);
  }
  final (rgba, w, h) = readPpm(File(args[0]).readAsBytesSync());
  final scale = args.length > 2 ? double.parse(args[2]) : 1.0;
  final sw = Stopwatch()..start();
  final (small, smallW, smallH) = shrink(rgba, w, h, 240);
  final levels = findLevels(small, smallW, smallH);
  final tLevels = sw.elapsedMilliseconds;
  var out = rgba, ow = w, oh = h;
  if (scale > 1) {
    ow = (w * scale).round();
    oh = (h * scale).round();
    sw.reset();
    out = upscaleSharpen(rgba, w, h, ow, oh);
  }
  final tUp = sw.elapsedMilliseconds;
  for (var p = 0; p < out.length; p += 4) {
    final (r, g, b) = levels.apply(out[p], out[p + 1], out[p + 2]);
    out[p] = r;
    out[p + 1] = g;
    out[p + 2] = b;
  }
  File(args[1]).writeAsBytesSync(writePpm(out, ow, oh));
  stdout.writeln('$levels levels ${tLevels}ms upscale ${w}x$h -> ${ow}x$oh ${tUp}ms');
}

(Uint8List, int, int) readPpm(Uint8List bytes) {
  var i = 0;
  String token() {
    while (bytes[i] == 0x23 || bytes[i] <= 0x20) {
      if (bytes[i] == 0x23) {
        while (bytes[i] != 0x0a) {
          i++;
        }
      }
      i++;
    }
    final start = i;
    while (bytes[i] > 0x20) {
      i++;
    }
    return String.fromCharCodes(bytes, start, i);
  }

  if (token() != 'P6') throw const FormatException('not a P6 PPM');
  final w = int.parse(token()), h = int.parse(token());
  token();
  i++;
  final rgba = Uint8List(w * h * 4);
  for (var p = 0, q = i; p < rgba.length; p += 4, q += 3) {
    rgba[p] = bytes[q];
    rgba[p + 1] = bytes[q + 1];
    rgba[p + 2] = bytes[q + 2];
    rgba[p + 3] = 255;
  }
  return (rgba, w, h);
}

Uint8List writePpm(Uint8List rgba, int w, int h) {
  final head = 'P6\n$w $h\n255\n'.codeUnits;
  final out = Uint8List(head.length + w * h * 3)..setAll(0, head);
  for (var p = 0, q = head.length; p < rgba.length; p += 4, q += 3) {
    out[q] = rgba[p];
    out[q + 1] = rgba[p + 1];
    out[q + 2] = rgba[p + 2];
  }
  return out;
}

/// Box-filtered copy [width] px wide, like the app's small measuring copy.
(Uint8List, int, int) shrink(Uint8List rgba, int w, int h, int width) {
  final height = (h * width / w).round();
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final x0 = x * w ~/ width, x1 = (x + 1) * w ~/ width, y0 = y * h ~/ height, y1 = (y + 1) * h ~/ height;
      for (var c = 0; c < 4; c++) {
        var s = 0, k = 0;
        for (var yy = y0; yy < y1; yy++) {
          for (var xx = x0; xx < x1; xx++) {
            s += rgba[(yy * w + xx) * 4 + c];
            k++;
          }
        }
        out[(y * width + x) * 4 + c] = s ~/ k;
      }
    }
  }
  return (out, width, height);
}
