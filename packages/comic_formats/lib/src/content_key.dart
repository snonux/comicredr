import 'dart:io';

import 'package:crypto/crypto.dart';

/// Identifies a book by content rather than path (design plan section 4):
/// SHA-1 of the first 64 KiB plus the file size. Rename a file, move it or
/// copy it to the phone, and its reading position follows it.
Future<String> contentKey(String path) async {
  final file = File(path);
  final size = await file.length();
  final raf = await file.open();
  try {
    final head = await raf.read(64 * 1024);
    return '${sha1.convert(head)}-$size';
  } finally {
    await raf.close();
  }
}
