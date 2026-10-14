import 'dart:io';
import 'dart:math';

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

import '../reader/thumbnails.dart';

/// How wide the library's covers are.
const coverWidth = 512;

/// Makes the library's cover of the book at [path] from page [page],
/// [coverWidth] pixels wide, and writes it to [file]; false when the page
/// cannot be read. Flutter's decoder scales a JPEG down as it decodes it,
/// where the pure Dart one the scan's worker has decodes every pixel: a
/// cover took that 0.3 s for a 1000 px scan and 4 s for a 4400 px one on a
/// laptop, and the first scan of a library waited for every one.
Future<bool> makeCover(String path, int page, String file) async {
  try {
    final doc = await BackgroundDocument.open(path);
    final Uint8List jpeg;
    try {
      jpeg = await thumbnailJpeg(doc, page, coverWidth);
    } finally {
      await doc.close();
    }
    await File(file).parent.create(recursive: true);
    // Written aside and renamed, so a half-written cover never shows; named
    // at random, since two scan workers can meet copies of one book.
    final tmp = File('$file.$pid.${Random().nextInt(1 << 32)}.tmp');
    try {
      await tmp.writeAsBytes(jpeg, flush: true);
      await tmp.rename(file);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
    return true;
  } catch (e) {
    debugPrint('Could not make the cover of $path: $e');
    return false;
  }
}
