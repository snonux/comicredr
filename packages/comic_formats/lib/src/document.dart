import 'dart:typed_data';

/// A page as encoded image bytes (JPEG, PNG, WebP) for the UI to decode.
///
/// Archives and folders hand back the stored image untouched and leave
/// downscaling to Flutter's native decoder; PDF (M6) renders at the target
/// size and fills in [width] and [height].
class PageImage {
  const PageImage(this.encoded, {this.width, this.height});

  final Uint8List encoded;
  final int? width;
  final int? height;
}

/// Metadata embedded in the book: ComicInfo.xml for archives and folders,
/// the document info dictionary for PDFs.
class ComicMeta {
  const ComicMeta({
    this.title,
    this.series,
    this.number,
    this.volume,
    this.year,
    this.writers = const [],
    this.artists = const [],
    this.summary,
    this.frontCoverPage,
    this.rightToLeft = false,
  });

  final String? title;
  final String? series;
  final String? number;
  final int? volume;
  final int? year;
  final List<String> writers;
  final List<String> artists;
  final String? summary;

  /// Page index ComicInfo marks as `FrontCover`, when it marks one.
  final int? frontCoverPage;
  final bool rightToLeft;
}

/// The one interface the reader sees (design plan section 2). Whether a page
/// came out of a ZIP, a PDF or a directory is invisible above this line.
abstract interface class ComicDocument {
  int get pageCount;

  /// Page [index] at roughly [targetWidth] x [targetHeight] device pixels.
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight});

  /// The page's original encoded bytes, or null where there are none (PDF).
  Future<Uint8List?> rawPage(int index);

  Future<ComicMeta?> embeddedMetadata();

  Future<void> close();
}
