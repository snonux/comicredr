import 'dart:convert';

import 'remote_store.dart';

/// Where one comic's objects live in the bucket (design plan section 13):
/// a folder per comic, named by its content key, so a rename on either
/// device changes nothing remotely.
///
///     <prefix>books/<content key>/manifest.json   written last, deleted first
///     <prefix>books/<content key>/comic.cbz        the file, its extension kept
///     <prefix>books/<content key>/files/…          instead, a folder book's files
///     <prefix>books/<content key>/cover.jpg
///     <prefix>books/<content key>/sidecar.crdb
class BookObjects {
  const BookObjects(this.prefix, this.contentKey);

  /// The configured prefix, ending in `/` or empty.
  final String prefix;
  final String contentKey;

  String get dir => '${booksDir(prefix)}$contentKey/';
  String get manifest => '${dir}manifest.json';
  String get cover => '${dir}cover.jpg';
  String get sidecar => '${dir}sidecar.crdb';

  /// The comic file, as `comic.<ext>`.
  String comic(String ext) => '${dir}comic.${ext.toLowerCase()}';

  /// A folder book's file at [relPath] (with `/`) inside it.
  String file(String relPath) => '${dir}files/$relPath';

  /// Where every comic's folder is.
  static String booksDir(String prefix) => '${prefix}books/';
}

/// What the bucket says about a comic: enough for the other device to show
/// it, cover and all, and to put it in the same place when downloaded.
class Manifest {
  const Manifest({
    required this.contentKey,
    required this.title,
    required this.format,
    required this.fileName,
    required this.size,
    required this.uploadedBy,
    required this.uploadedAt,
    this.series,
    this.number,
    this.year,
    this.pageCount,
    this.folder = '',
    this.ext,
    this.files = const [],
  });

  static const version = 1;

  final String contentKey;
  final String title;
  final String? series;
  final String? number;
  final int? year;
  final int? pageCount;

  /// The format as the library knows it: zip, pdf, folder, cbt, epub, image.
  final String format;

  /// The comic's name on disk: the file, or the folder of a folder book.
  final String fileName;

  /// Its folder relative to its library folder, with `/`, empty at the top.
  final String folder;

  /// The comic file's extension, lower case, without the dot; null for a
  /// folder book.
  final String? ext;

  /// Bytes: the file, or all of a folder book's files together.
  final int size;

  /// A folder book's files, relative to it, with `/`, and their sizes.
  final List<({String path, int size})> files;

  /// The device name that uploaded it, for "uploaded from ThinkPad".
  final String uploadedBy;
  final DateTime uploadedAt;

  bool get isFolder => format == 'folder';

  /// Where the comic goes under a library folder, with `/`.
  String get relPath => folder.isEmpty ? fileName : '$folder/$fileName';

  Map<String, Object?> toJson() => {
    'version': version,
    'content_key': contentKey,
    'title': title,
    'series': ?series,
    'number': ?number,
    'year': ?year,
    'pages': ?pageCount,
    'format': format,
    'file_name': fileName,
    'folder': folder,
    'ext': ?ext,
    'size': size,
    if (files.isNotEmpty)
      'files': [
        for (final f in files) {'path': f.path, 'size': f.size},
      ],
    'uploaded_by': uploadedBy,
    'uploaded_at': uploadedAt.toUtc().toIso8601String(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Reads a manifest; null when [text] is not one this app understands.
  static Manifest? decode(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, Object?>) return null;
      final key = j['content_key'], title = j['title'], format = j['format'], name = j['file_name'];
      if (key is! String || title is! String || format is! String || name is! String) return null;
      if (name.isEmpty || name.contains('/') || name == '.' || name == '..') return null;
      final folder = j['folder'] is String ? j['folder']! as String : '';
      // Never a path out of the library folder.
      if (folder.split('/').any((s) => s == '..') || folder.startsWith('/')) return null;
      return Manifest(
        contentKey: key,
        title: title,
        series: j['series'] as String?,
        number: j['number'] as String?,
        year: j['year'] as int?,
        pageCount: j['pages'] as int?,
        format: format,
        fileName: name,
        folder: folder,
        ext: j['ext'] as String?,
        size: (j['size'] as int?) ?? 0,
        files: [
          for (final f in (j['files'] as List<Object?>?) ?? const [])
            if (f case {'path': final String path, 'size': final int size}
                when !path.startsWith('/') && !path.split('/').contains('..'))
              (path: path, size: size),
        ],
        uploadedBy: (j['uploaded_by'] as String?) ?? '',
        uploadedAt: DateTime.tryParse((j['uploaded_at'] as String?) ?? '')?.toLocal() ?? DateTime(1970),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The sidecar object's metadata names: when its sidecar was written, and
/// by which device (design plan section 13, "Which copy is newer").
const writtenAtMeta = 'written-at';
const deviceMeta = 'device';

/// Which way a sidecar goes: the newest `written_at` wins, whole file.
enum SidecarMove {
  /// The same on both sides, or neither has one.
  none,

  /// The local one is newer, or the bucket has none: upload it.
  push,

  /// The bucket's is newer, or there is none here: download it.
  pull,
}

/// Compares the local sidecar's `written_at` with the bucket's, both in
/// milliseconds; null where there is none.
SidecarMove compareSidecars({required int? local, required int? remote}) {
  if (local == null && remote == null) return SidecarMove.none;
  if (remote == null) return SidecarMove.push;
  if (local == null) return SidecarMove.pull;
  if (local == remote) return SidecarMove.none;
  return local > remote ? SidecarMove.push : SidecarMove.pull;
}

/// The content keys of every comic on the shelf: those whose manifest is
/// in the bucket. One listing of `books/` (a comic whose upload was cut off
/// has no manifest and does not count).
Future<Set<String>> listShelf(RemoteStore store, String prefix) async {
  final dir = BookObjects.booksDir(prefix);
  final keys = <String>{};
  await for (final o in store.list(dir)) {
    final rest = o.key.substring(dir.length);
    final slash = rest.indexOf('/');
    if (slash > 0 && rest.substring(slash + 1) == 'manifest.json') keys.add(rest.substring(0, slash));
  }
  return keys;
}

/// Removes a comic from the bucket: the manifest first, so no device sees
/// it any more, then everything else in its folder.
Future<void> removeFromShelf(RemoteStore store, BookObjects at) async {
  await store.delete(at.manifest);
  final rest = [await for (final o in store.list(at.dir)) o.key];
  for (final k in rest) {
    await store.delete(k);
  }
}
