import 'dart:io';

import 'package:crypto/crypto.dart';

import 'folder.dart';

/// Identifies a book by content rather than path (design plan section 4):
/// SHA-1 of the first 64 KiB plus the file size. Rename a file, move it or
/// copy it to the phone, and its reading position follows it.
///
/// A folder book hashes its page names and the first 64 KiB of its first
/// page, with the pages' total size, so renaming the folder keeps the key
/// and replacing or adding a page changes it.
Future<String> contentKey(String path) async {
  if (await FileSystemEntity.isDirectory(path)) return _folderKey(path);
  final file = File(path);
  final size = await file.length();
  return '${sha1.convert(await _head(file))}-$size';
}

Future<String> _folderKey(String path) async {
  final doc = FolderDocument.open(path);
  var size = 0;
  for (final name in doc.pageNames) {
    size += await File('${doc.root}/$name').length();
  }
  final head = await _head(File('${doc.root}/${doc.pageNames.first}'));
  final digest = sha1.convert([...head, ...doc.pageNames.join('\n').codeUnits]);
  return '$digest-$size';
}

Future<List<int>> _head(File file) async {
  final raf = await file.open();
  try {
    return await raf.read(64 * 1024);
  } finally {
    await raf.close();
  }
}
