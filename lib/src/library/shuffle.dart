import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_paths.dart';
import '../reader/thumbnails.dart';
import 'library_store.dart';
import 'providers.dart';

/// Shuffle on the tabs of covers (`S`): each book's tile shows a random page
/// of it instead of its cover. [seed] picks the pages; a new one (`gs`,
/// turning shuffle on, walking into a folder) picks others, and the same
/// seed keeps them while the grid scrolls.
int shufflePage(String bookKey, int pageCount, int seed) {
  if (pageCount <= 1) return 0;
  // Never the cover: that is what the tile shows without shuffle.
  return 1 + math.Random(Object.hash(bookKey, seed)).nextInt(pageCount - 1);
}

/// A folder's or series' tile in shuffle (its item id [group]): one of its
/// comics, picked by [seed] as [shufflePage] picks pages. Null when none can
/// be opened here.
LibraryBook? shuffleBook(String group, List<LibraryBook> books, int seed) {
  final local = books.where((b) => !b.remoteOnly).toList();
  if (local.isEmpty) return null;
  return local[math.Random(Object.hash(group, seed)).nextInt(local.length)];
}

/// Makes the pages shuffle shows, as the page grid's thumbnails
/// (`<cache>/covers/pages/<content key>/<page>.jpg`, 256 px wide, and
/// `w512/<page>.jpg` for covers sized by hand to more than 332.8 device
/// pixels; never at the usual cover size), so a page the grid made is
/// reused and the other way round.
///
/// Only tiles on screen ask; the newest request is made first, two at a
/// time, and a tile scrolled away drops its request. Each page opens its
/// book on a worker ([BackgroundDocument], so PDFs keep to the one PDFium
/// isolate) and closes it again straight after: nothing stays open, so the
/// phone holds no more than two pages' worth at once.
class ShufflePages {
  ShufflePages({required this.dir, Future<ComicDocument> Function(String path)? open, this.parallel = 2})
    : _open = open ?? BackgroundDocument.open;

  /// `<cache>/covers/pages`.
  final String dir;
  final Future<ComicDocument> Function(String path) _open;
  final int parallel;

  /// The usual size, the page grid's too.
  static const width = 256;

  /// The sizes a shuffled page is made in: the page grid's first two
  /// ([Thumbnails.sizes]). No bigger than the 512 px of the cover the page
  /// stands in for: a screenful of big tiles then costs a phone what the
  /// covers cost it, about 1.5 MB decoded each.
  static const sizes = [256, 512];

  /// The size for a tile [px] device pixels wide in a grid sized by hand
  /// (the usual cover size keeps to [width], see `coverPictureSizes`), by the page grid's rule
  /// ([Thumbnails.sizeFor]): the smallest that needs enlarging by no more
  /// than a third. A tile over 665 pixels wide shows the 512 px page
  /// scaled up further, and soft.
  static int sizeFor(double px) => sizes.firstWhere((w) => w * 1.3 >= px, orElse: () => sizes.last);

  final _waiting = <_Page, (String, Completer<String?>)>{};
  final _running = <_Page, Future<String?>>{};
  int _busy = 0;
  bool _closed = false;

  static const _maxWaiting = 64;

  /// The file of [bookKey]'s page [index], [size] pixels wide: where the
  /// page grid keeps it ([Thumbnails.pathOf]).
  String pathOf(String bookKey, int index, [int size = width]) =>
      size == width ? '$dir/$bookKey/${index + 1}.jpg' : '$dir/$bookKey/w$size/${index + 1}.jpg';

  /// The file of page [index] of [book], [size] pixels wide, made first if
  /// need be; null when the page cannot be read or the tile moved on.
  Future<String?> get(LibraryBook book, int index, {int size = width}) {
    final path = pathOf(book.key, index, size);
    if (File(path).existsSync()) return Future.value(path);
    if (_closed) return Future.value(); // Nothing would ever make it now.
    final key = (book.key, index, size);
    if (_running[key] case final running?) return running;
    final (_, c) = _waiting.remove(key) ?? (book.path, Completer<String?>());
    _waiting[key] = (book.path, c);
    while (_waiting.length > _maxWaiting) {
      _waiting.remove(_waiting.keys.first)!.$2.complete(null);
    }
    _pump();
    return c.future;
  }

  /// The tile showing [bookKey]'s page [index] at [size] is gone.
  void cancel(String bookKey, int index, {int size = width}) =>
      _waiting.remove((bookKey, index, size))?.$2.complete(null);

  void close() {
    _closed = true;
    for (final (_, c) in _waiting.values) {
      c.complete(null);
    }
    _waiting.clear();
  }

  void _pump() {
    while (!_closed && _busy < parallel && _waiting.isNotEmpty) {
      final key = _waiting.keys.last;
      final (bookPath, c) = _waiting.remove(key)!;
      _busy++;
      final made = _make(bookPath, key).whenComplete(() {
        _busy--;
        _running.remove(key);
        _pump();
      });
      _running[key] = made;
      c.complete(made);
    }
  }

  Future<String?> _make(String bookPath, _Page key) async {
    final (bookKey, index, size) = key;
    final path = pathOf(bookKey, index, size);
    ComicDocument? doc;
    try {
      if (await File(path).exists()) return path;
      doc = await _open(bookPath);
      if (_closed || index >= doc.pageCount) return null;
      final jpeg = await thumbnailJpeg(doc, index, size);
      await File(path).parent.create(recursive: true);
      // Written aside and renamed, as the page grid does.
      final tmp = await File('$path.$pid.tmp').writeAsBytes(jpeg, flush: true);
      await tmp.rename(path);
      return path;
    } catch (e) {
      if (!_closed) debugPrint('Could not make a shuffle page of $bookPath: $e');
      return null;
    } finally {
      await doc?.close().catchError((_) {});
    }
  }
}

/// A book's content key, a page of it and the size it is wanted in.
typedef _Page = (String, int, int);

final shufflePagesProvider = Provider<ShufflePages>((ref) {
  final s = ShufflePages(dir: pageThumbsRoot(ref.watch(coverDirProvider)));
  ref.onDispose(s.close);
  return s;
});

/// A book's tile picture in shuffle: its page [page], [size] pixels wide
/// (one of [ShufflePages.sizes]), with the cover in its place until that
/// page is ready.
class ShuffledPage extends ConsumerStatefulWidget {
  const ShuffledPage({
    super.key,
    required this.book,
    required this.page,
    required this.cover,
    this.size = ShufflePages.width,
    this.decodeWidth,
  });

  final LibraryBook book;
  final int page;
  final int size;

  /// The most pixels wide the page is decoded, when that is less than its
  /// file has: small tiles are many, and each would hold the whole 256 px
  /// page in memory. Null for the file's own width.
  final int? decodeWidth;

  /// What shows until the page is made, or when it cannot be.
  final Widget cover;

  @override
  ConsumerState<ShuffledPage> createState() => _ShuffledPageState();
}

class _ShuffledPageState extends ConsumerState<ShuffledPage> {
  /// The file showing, and the size it is: the usual one for a moment
  /// when the bigger one asked for is still being made.
  String? _path;
  int _shown = ShufflePages.width;
  late ShufflePages _pages;

  @override
  void initState() {
    super.initState();
    _pages = ref.read(shufflePagesProvider);
    _load();
  }

  @override
  void didUpdateWidget(ShuffledPage old) {
    super.didUpdateWidget(old);
    final samePage = old.book.key == widget.book.key && old.page == widget.page;
    if (samePage && old.size == widget.size) return;
    _pages.cancel(old.book.key, old.page, size: old.size);
    // Zoomed: the same page stays up, at the size it has, until the new
    // one is there. Another page starts from nothing.
    _load(keep: samePage);
  }

  void _load({bool keep = false}) {
    final book = widget.book.key, page = widget.page, size = widget.size;
    if (!keep) _path = null;
    // A page made before shows at once, with no cover flashing first; a
    // big one not made yet shows the usual size meanwhile, when that is.
    for (final have in {size, ShufflePages.width}) {
      final known = _pages.pathOf(book, page, have);
      if (!File(known).existsSync()) continue;
      _path = known;
      _shown = have;
      if (have == size) return;
      break;
    }
    unawaited(
      _pages.get(widget.book, page, size: size).then((path) {
        if (!mounted || path == null) return;
        if (widget.book.key != book || widget.page != page || widget.size != size) return;
        setState(() {
          _path = path;
          _shown = size;
        });
      }),
    );
  }

  @override
  void dispose() {
    _pages.cancel(widget.book.key, widget.page, size: widget.size);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (path == null) return widget.cover;
    return Image.file(
      File(path),
      key: Key('shuffled-${widget.book.key}-${widget.page}'),
      fit: BoxFit.cover,
      // The file's width or the tile's decode width, each one of a few:
      // most zoom steps decode nothing again.
      cacheWidth: math.min(_shown, widget.decodeWidth ?? _shown),
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.cover,
    );
  }
}
