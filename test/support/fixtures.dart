import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A 1x1 PNG. Every page of a fixture book is this, plus a trailing byte
/// that PNG decoders ignore, so pages stay distinguishable.
final Uint8List png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Writes a CBZ of [pages] pages into [dir] and returns its path.
String writeBook(Directory dir, String name, int pages) {
  final a = Archive();
  for (var i = 1; i <= pages; i++) {
    a.addFile(ArchiveFile.bytes('page$i.png', [...png, i]));
  }
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
  return path;
}
