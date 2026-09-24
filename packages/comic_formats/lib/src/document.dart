import 'dart:typed_data';

/// A part of a page, as fractions (0..1) of its width and height.
typedef PageRegion = ({double left, double top, double width, double height});

/// A page for the UI to decode: encoded image bytes (JPEG, PNG, WebP), or
/// raw BGRA pixels when [bgra] is set.
///
/// Archives and folders hand back the stored image untouched and leave
/// downscaling to Flutter's native decoder; PDF renders at the target size
/// into raw pixels and fills in [width] and [height].
class PageImage {
  const PageImage(this.bytes, {this.width, this.height, this.bgra = false, this.region})
    : assert(!bgra || (width != null && height != null));

  final Uint8List bytes;
  final int? width;
  final int? height;

  /// Whether [bytes] are raw pixels, 4 bytes each in B, G, R, A order, row
  /// after row, rather than an encoded image.
  final bool bgra;

  /// The part of the page these pixels show, when a source was asked for a
  /// region and drew only that; null for the whole page.
  final PageRegion? region;
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
  /// Sources that render (PDF) fit the page inside that box; sources that
  /// store images return them as stored.
  ///
  /// With a [region], sources that render may draw only that part of the
  /// page, at the scale the whole page would have in the box, and say so in
  /// [PageImage.region]; a zoomed-in view then never needs the whole page
  /// at that scale. Other sources ignore it.
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region});

  /// The page's original encoded bytes, or null where there are none (PDF).
  Future<Uint8List?> rawPage(int index);

  /// Every page's size in pixels (points for a PDF), in order, read without
  /// decoding the pages; null for a page whose size could not be read. What
  /// counts is the shape: spread mode shows a wide page on its own.
  Future<List<(int, int)?>> pageSizes();

  Future<ComicMeta?> embeddedMetadata();

  Future<void> close();
}
