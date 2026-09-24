import 'dart:io';
import 'dart:isolate';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/meta_edits.dart';
import '../library/providers.dart';
import '../providers.dart';
import 'guided.dart';
import 'open_book.dart';
import 'panel_detector.dart';
import 'reader_notifier.dart';

/// Everything the details view (`I`) says about one comic: the file, its
/// pages and how good their scans are, its metadata, how far it has been
/// read and what panel detection made of it. [readComicReport] gathers it
/// from page headers and the index, never decoding a page.
class ComicReport {
  const ComicReport({
    required this.path,
    required this.contentKey,
    required this.kind,
    required this.bytes,
    required this.modified,
    required this.sidecars,
    required this.pages,
    required this.meta,
    required this.edited,
    required this.metaSource,
    required this.reading,
    required this.detection,
  });

  final String path;
  final String contentKey;
  final BookKind kind;

  /// The file's size, or all the pages' for a folder.
  final int bytes;
  final DateTime? modified;

  /// Where the sidecar is written first, then any other copy it is read
  /// from, each with its size when it exists.
  final List<({String path, int? bytes})> sidecars;
  final PageSummary pages;
  final ComicMeta? meta;

  /// The fields edited by hand in the library (`e`).
  final Set<MetaField> edited;

  /// Where the metadata comes from: ComicInfo.xml, the EPUB's package file,
  /// or only the file name.
  final String metaSource;
  final ReadingSummary reading;
  final DetectionSummary detection;

  bool get isPdf => kind == BookKind.pdf;

  /// How the format reads in the view: what the first bytes say, and the
  /// name's extension when it says otherwise (a `.cbr` that is a ZIP).
  String get formatLabel {
    final label = switch (kind) {
      BookKind.cbz => 'CBZ (ZIP archive)',
      BookKind.cbt => 'CBT (tar archive)',
      BookKind.epub => 'EPUB (image pages)',
      BookKind.pdf => 'PDF',
      BookKind.folder => 'Folder of page images',
      BookKind.rar => 'RAR',
      BookKind.unknown => 'Unknown',
    };
    final ext = p.extension(path).toLowerCase();
    final expected = switch (kind) {
      BookKind.cbz => {'.cbz', '.zip'},
      BookKind.cbt => {'.cbt', '.tar'},
      BookKind.epub => {'.epub'},
      BookKind.pdf => {'.pdf'},
      _ => null,
    };
    return expected != null && ext.isNotEmpty && !expected.contains(ext) ? '$label, named $ext' : label;
  }
}

/// The pages of a book in numbers: what [PageFacts] says of each, gathered.
class PageSummary {
  PageSummary(this.facts);

  final List<PageFacts> facts;

  int get count => facts.length;

  /// Pages by stored format, most common first.
  List<(String, int)> get formats {
    final by = <String, int>{};
    for (final f in facts) {
      by[f.format] = (by[f.format] ?? 0) + 1;
    }
    return by.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  List<PageFacts> get _sized => [
    for (final f in facts)
      if (f.width != null && f.height != null) f,
  ];

  /// The smallest, middle and largest page, by area.
  ({PageFacts min, PageFacts median, PageFacts max})? get sizes {
    final s = _sized..sort((a, b) => (a.width! * a.height!).compareTo(b.width! * b.height!));
    if (s.isEmpty) return null;
    return (min: s.first, median: s[s.length ~/ 2], max: s.last);
  }

  /// Pages at least 1.1 times wider than tall: scanned double-page spreads,
  /// which two-page mode shows alone.
  int get wide => _sized.where((f) => f.width! >= 1.1 * f.height!).length;

  /// The JPEG quality settings, lowest, middle and highest.
  ({int min, int median, int max})? get jpegQuality {
    final q = [
      for (final f in facts)
        if (f.quality != null) f.quality!,
    ]..sort();
    if (q.isEmpty) return null;
    return (min: q.first, median: q[q.length ~/ 2], max: q.last);
  }

  int get progressive => facts.where((f) => f.progressive).length;
  int get gray => facts.where((f) => f.gray).length;

  /// The density most pages claim, when they claim one.
  int? get dpi {
    final d = [
      for (final f in facts)
        if (f.dpi != null) f.dpi!,
    ]..sort();
    return d.isEmpty ? null : d[d.length ~/ 2];
  }

  int get storedBytes => facts.fold<int>(0, (sum, f) => sum + (f.bytes ?? 0));

  /// Whether every page is the same size.
  bool get uniform {
    final s = _sized;
    return s.isNotEmpty && s.every((f) => f.width == s.first.width && f.height == s.first.height);
  }
}

/// How sharp pages of [height] pixels are on a screen [screen] device
/// pixels tall, shown whole: a verdict and whether clean-up's enlarging
/// (`c`) would help. What the reader needs here is the height, since a
/// page is shown whole top to bottom, and guided view zooms in further.
({String verdict, bool soft}) sharpness(int height, double screen) {
  final r = height / screen;
  if (r >= 2) return (verdict: 'Plenty of pixels: sharp even zoomed in on a panel', soft: false);
  if (r >= 1) return (verdict: 'Sharp shown whole; softer zoomed in on a panel', soft: false);
  if (r >= 0.6) return (verdict: 'A little soft on this screen: fewer pixels than it shows', soft: true);
  return (verdict: 'Low resolution for this screen', soft: true);
}

/// What a JPEG quality setting means for the eye.
String jpegVerdict(int q) => q >= 90
    ? 'high, no visible artefacts'
    : q >= 75
    ? 'normal'
    : q >= 50
    ? 'low: blocky edges and halos around lines likely'
    : 'very low: heavy blocking';

/// Where the reader is in the book and how long it has been read.
class ReadingSummary {
  const ReadingSummary({
    this.page,
    this.percent,
    this.finished = false,
    this.updatedAt,
    this.sittings = 0,
    this.time = Duration.zero,
    this.pagesShown = 0,
    this.firstRead,
    this.bookmarks = 0,
    this.marks = 0,
    this.collections = const [],
  });

  final int? page;
  final double? percent;
  final bool finished;
  final DateTime? updatedAt;
  final int sittings;
  final Duration time;
  final int pagesShown;
  final DateTime? firstRead;
  final int bookmarks;
  final int marks;
  final List<String> collections;
}

/// What detection found on one page.
class PageDetection {
  const PageDetection({required this.page, required this.found, required this.panels});

  final int page;
  final DetectedPage found;

  /// The page as guided view sees it: the gate's verdict and stops.
  final PagePanels panels;

  int get frames => found.frames.length;
  int get balloons => found.balloons.where((b) => b.kind != PanelKind.caption).length;
  int get captions => found.balloons.where((b) => b.kind == PanelKind.caption).length;
  bool get guided => panels.gate.passed;
  bool get trimmed => !found.trim.isFull;
  int get outlined => found.frames.where((f) => f.shape != null).length;

  /// The frames' mean confidence; null with none.
  double? get confidence =>
      found.frames.isEmpty ? null : found.frames.fold(0.0, (s, f) => s + f.confidence) / found.frames.length;
}

/// Detection across the book, with the detector this install runs.
class DetectionSummary {
  const DetectionSummary({
    required this.detector,
    required this.current,
    required this.pageCount,
    required this.pages,
    this.stale = 0,
  });

  /// Which detector this install runs, in words.
  final String detector;

  /// This install's detector as [sourceLabel] puts it.
  final String current;
  final int pageCount;

  /// Analysed pages, in page order, by a run as good as this detector's.
  final List<PageDetection> pages;

  /// Pages only an older detector has looked at; they are analysed again
  /// when shown, or by the library pass.
  final int stale;

  int get frames => pages.fold(0, (s, d) => s + d.frames);
  int get balloons => pages.fold(0, (s, d) => s + d.balloons);
  int get captions => pages.fold(0, (s, d) => s + d.captions);
  int get guided => pages.where((d) => d.guided).length;
  int get trimmed => pages.where((d) => d.trimmed).length;
  int get outlined => pages.fold(0, (s, d) => s + d.outlined);
  int get millis => pages.fold(0, (s, d) => s + d.found.millis);

  /// Mean confidence over every frame and every balloon.
  ({double? frames, double? balloons}) get confidence {
    double? mean(Iterable<Panel> ps) {
      final l = ps.toList();
      return l.isEmpty ? null : l.fold(0.0, (s, f) => s + f.confidence) / l.length;
    }

    return (frames: mean(pages.expand((d) => d.found.frames)), balloons: mean(pages.expand((d) => d.found.balloons)));
  }

  /// Why pages are shown whole, most common first: the gate's first
  /// reason, with its numbers taken out so alike pages count together.
  List<(String, int)> get wholeReasons {
    final by = <String, int>{};
    for (final d in pages.where((d) => !d.guided)) {
      final r = wholeReason(d.panels.gate.reasons.first);
      by[r] = (by[r] ?? 0) + 1;
    }
    return by.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Which detectors found the panels: 'trained model' or 'classic CV',
  /// with how many pages each.
  List<(String, int)> get sources {
    final by = <String, int>{};
    for (final d in pages) {
      final s = sourceLabel(d.found.source, d.found.version);
      by[s] = (by[s] ?? 0) + 1;
    }
    return by.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }
}

/// A gate reason in general words: "3 panel(s): nothing…" and "1 panel(s):
/// nothing…" are the same reason for the tally.
String wholeReason(String reason) {
  if (reason.contains('nothing to guide through')) return 'fewer than 2 panels';
  if (reason.contains('implausibly many')) return 'too many panels';
  if (reason.contains('overlap')) return 'panels overlap';
  if (reason.contains('is the whole page')) return 'one panel is the whole page';
  if (reason.contains('scraps')) return 'looks like an ad or a text page';
  if (reason.contains('covers')) return 'panels cover too little of the page';
  return reason;
}

/// A detector and its version in words.
String sourceLabel(PanelSource source, int version) => switch (source) {
  PanelSource.model => 'trained model, generation ${detectorGeneration(version)}',
  PanelSource.classicCv => 'classic computer vision, version $version',
  PanelSource.manual => 'drawn by hand',
};

/// Page facts already read, by content key: they never change for a key.
final _factsCache = <String, List<PageFacts>>{};
final _pdfCache = <String, List<PdfImage>>{};

void _remember<T>(Map<String, T> cache, String key, T value) {
  cache.remove(key);
  cache[key] = value;
  while (cache.length > 16) {
    cache.remove(cache.keys.first);
  }
}

/// The images inside the PDF at [path], read once per content [key] on a
/// short-lived isolate: the file is scanned as bytes, PDFium is not used.
Future<List<PdfImage>> pdfImagesOf(String path, String key) async {
  if (_pdfCache[key] case final hit?) return hit;
  final found = await Isolate.run(() => pdfImages(path));
  _remember(_pdfCache, key, found);
  return found;
}

/// Gathers the [ComicReport] of [book] (open in the reader, or opened for
/// the purpose by the library). [pageFacts] reads the page headers through
/// the book's own worker, so a PDF stays on the one PDFium isolate.
Future<ComicReport> readComicReport(WidgetRef ref, OpenBook book) async {
  final db = ref.read(databaseProvider);
  final key = book.key;
  final kind = book.folder ? BookKind.folder : bookKind(book.path);

  var facts = _factsCache[key];
  if (facts == null) {
    facts = await book.doc.pageFacts();
    _remember(_factsCache, key, facts);
  }
  final pages = PageSummary(facts);

  int bytes;
  DateTime? modified;
  if (book.folder) {
    bytes = pages.storedBytes;
    modified = (await Directory(book.path).stat()).modified;
  } else {
    final stat = await File(book.path).stat();
    bytes = stat.size;
    modified = stat.modified;
  }

  final sidecars = <({String path, int? bytes})>[];
  try {
    for (final s in await ref.read(sidecarSyncProvider).sidecarsOf(book.path, folder: book.folder)) {
      final f = File(s);
      sidecars.add((path: s, bytes: await f.exists() ? await f.length() : null));
    }
  } catch (_) {
    // Nowhere to write one: the view says so.
  }

  final edited = <MetaField>{};
  try {
    edited.addAll((await ref.read(libraryStoreProvider).edits(key)).keys);
  } catch (_) {}
  var metaSource = 'the file name';
  try {
    if (await book.doc.embeddedMetadata() != null) {
      metaSource = kind == BookKind.epub ? 'the EPUB (ComicInfo.xml or its package file)' : 'ComicInfo.xml';
    }
  } on FormatException {
    // A broken ComicInfo.xml: the name it is.
  }

  final progress = await (db.select(db.progress)..where((r) => r.contentKey.equals(key))).getSingleOrNull();
  final log =
      await (db.select(db.readLog)
            ..where((r) => r.contentKey.equals(key))
            ..orderBy([(r) => OrderingTerm(expression: r.startedAt)]))
          .get();
  final marks = await (db.select(db.bookmarks)..where((b) => b.contentKey.equals(key) & b.deletedAt.isNull())).get();
  final collections = await (db.select(
    db.collectionBooks,
  )..where((c) => c.contentKey.equals(key) & c.removedAt.isNull())).get();
  final reading = ReadingSummary(
    page: progress?.page,
    percent: progress?.percent,
    finished: progress?.finished ?? false,
    updatedAt: progress?.updatedAt,
    sittings: log.length,
    time: log.fold(Duration.zero, (t, r) => t + r.endedAt.difference(r.startedAt)),
    pagesShown: log.fold(0, (n, r) => n + r.pages),
    firstRead: log.firstOrNull?.startedAt,
    bookmarks: marks.where((m) => m.mark == null).length,
    marks: marks.where((m) => m.mark != null).length,
    collections: [for (final c in collections) c.name]..sort(),
  );

  final detector = await ref.read(panelDetectorProvider.future);
  final found = await ref.read(panelStoreProvider).load(key, source: detector.source, version: detector.version);
  final analysed = await (db.select(db.analysedPages)..where((a) => a.contentKey.equals(key))).get();
  final stale = analysed.map((a) => a.page).toSet().difference(found.keys.toSet()).length;
  final model = detector.model;
  final detection = DetectionSummary(
    detector: model == null
        ? 'Classic computer vision (no trained model installed): frames only, no balloons'
        : 'Trained model, generation ${detectorGeneration(model.version)}: ${model.path}',
    current: sourceLabel(detector.source, detector.version),
    pageCount: book.doc.pageCount,
    stale: stale,
    pages: [
      for (final page in found.keys.toList()..sort())
        PageDetection(
          page: page,
          found: found[page]!,
          panels: PagePanels(found[page]!.frames, found[page]!.balloons, found[page]!.trim),
        ),
    ],
  );

  return ComicReport(
    path: book.path,
    contentKey: key,
    kind: kind,
    bytes: bytes,
    modified: modified,
    sidecars: sidecars,
    pages: pages,
    meta: mergeMeta(book.meta, parseFileName(p.basename(book.path))),
    edited: edited,
    metaSource: metaSource,
    reading: reading,
    detection: detection,
  );
}

/// [n] bytes for people: 12.3 MB.
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v >= 100 ? v.round() : v.toStringAsFixed(1)} ${units[u]}';
}

/// [d] for people: 2 h 5 min, 4 min, 30 s.
String formatDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${d.inMinutes % 60} min';
}
