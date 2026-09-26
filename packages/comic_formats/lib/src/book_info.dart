import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'content_key.dart';
import 'document.dart';
import 'file_name.dart';
import 'open.dart';

/// What the library scan learns about one book (design plan section 4,
/// phase two): its content key, page count and metadata, and where it put
/// the cover. Plain data, so it crosses back from the scan isolate.
class BookInfo {
  const BookInfo({
    required this.contentKey,
    required this.kind,
    required this.pageCount,
    required this.meta,
    required this.fromComicInfo,
    this.cover,
  });

  final String contentKey;
  final BookKind kind;
  final int pageCount;

  /// ComicInfo.xml where it says something, the file name for the rest.
  final ComicMeta meta;

  /// Whether the book carried a ComicInfo.xml.
  final bool fromComicInfo;

  /// The cover image written, or null if the cover page could not be read.
  final String? cover;
}

/// Opens the book at [path] on the calling isolate (the scan runs it on a
/// worker) and reads what the library needs. Writes the cover, [coverWidth]
/// pixels wide, as a JPEG into [coverDir] named after the content key, unless
/// it is already there. Throws [FormatException] for a file that is not a
/// readable book, including a RAR.
Future<BookInfo> readBookInfo(String path, {required String coverDir, int coverWidth = 512}) async {
  final kind = bookKind(path);
  final doc = await openDocument(path);
  try {
    final key = await contentKey(path);
    ComicMeta? embedded;
    try {
      embedded = await doc.embeddedMetadata();
    } on FormatException {
      embedded = null;
    }
    final name = path.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
    final meta = mergeMeta(embedded, parseFileName(name));
    final coverPath = '$coverDir/$key.jpg';
    String? cover = coverPath;
    if (!File(coverPath).existsSync()) {
      final page = (embedded?.frontCoverPage ?? 0).clamp(0, doc.pageCount - 1);
      try {
        final bytes = await coverJpeg(doc, page, width: coverWidth);
        Directory(coverDir).createSync(recursive: true);
        // Written aside and renamed, so a half-written cover never shows.
        // Named at random too: two scan workers can meet copies of one book.
        final tmp = File('$coverPath.$pid.${Random().nextInt(1 << 32)}.tmp');
        try {
          tmp.writeAsBytesSync(bytes, flush: true);
          tmp.renameSync(coverPath);
        } finally {
          if (tmp.existsSync()) tmp.deleteSync();
        }
      } catch (_) {
        cover = null; // A book with an unreadable cover is still a book.
      }
    }
    return BookInfo(
      contentKey: key,
      kind: kind,
      pageCount: doc.pageCount,
      meta: meta,
      fromComicInfo: embedded != null,
      cover: cover,
    );
  } finally {
    await doc.close();
  }
}

/// Page [index] of [doc] scaled to [width] pixels wide, as JPEG.
Future<Uint8List> coverJpeg(ComicDocument doc, int index, {int width = 512}) async {
  final raw = await doc.rawPage(index);
  img.Image? image;
  if (raw != null) {
    image = img.decodeImage(raw);
  } else {
    // PDFs render straight to the size asked for.
    final p = await doc.page(index, targetWidth: width, targetHeight: width * 4);
    if (p.bgra) {
      image = img.Image.fromBytes(
        width: p.width!,
        height: p.height!,
        bytes: p.bytes.buffer,
        bytesOffset: p.bytes.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
    } else {
      image = img.decodeImage(p.bytes);
    }
  }
  if (image == null) throw FormatException('Cannot decode page ${index + 1}');
  if (image.width > width) image = img.copyResize(image, width: width, interpolation: img.Interpolation.average);
  return img.encodeJpg(image, quality: 75);
}

/// Embedded metadata first, the file name for whatever it leaves out
/// (design plan section 4).
ComicMeta mergeMeta(ComicMeta? embedded, ComicMeta fromName) {
  if (embedded == null) return fromName;
  return ComicMeta(
    title: embedded.title ?? fromName.title,
    series: embedded.series ?? fromName.series,
    number: embedded.number ?? (embedded.series == null ? fromName.number : null),
    volume: embedded.volume ?? fromName.volume,
    year: embedded.year ?? fromName.year,
    writers: embedded.writers,
    artists: embedded.artists,
    summary: embedded.summary,
    frontCoverPage: embedded.frontCoverPage,
    rightToLeft: embedded.rightToLeft,
  );
}
