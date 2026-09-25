import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/thumbnails.dart';
import 'library_store.dart';
import 'providers.dart';

/// Shuffle on the Folders tab (`S`): each book's tile shows a random page
/// of it instead of its cover. [seed] picks the pages; a new one (`gs`,
/// turning shuffle on, walking into a folder) picks others, and the same
/// seed keeps them while the grid scrolls.
int shufflePage(String bookKey, int pageCount, int seed) {
  if (pageCount <= 1) return 0;
  // Never the cover: that is what the tile shows without shuffle.
  return 1 + math.Random(Object.hash(bookKey, seed)).nextInt(pageCount - 1);
}

/// Makes the pages shuffle shows, as the page grid's thumbnails
/// (`<cache>/covers/pages/<content key>/<page>.jpg`, 256 px wide), so a page
/// the grid made is reused and the other way round.
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

  static const width = 256;

  final _waiting = <(String, int), (String, Completer<String?>)>{};
  final _running = <(String, int), Future<String?>>{};
  int _busy = 0;
  bool _closed = false;

  static const _maxWaiting = 64;

  /// The file of [book]'s page [index] at the page grid's default size.
  String pathOf(String bookKey, int index) => '$dir/$bookKey/${index + 1}.jpg';

  /// The file of page [index] of [book], made first if need be; null when
  /// the page cannot be read or the tile moved on.
  Future<String?> get(LibraryBook book, int index) {
    final path = pathOf(book.key, index);
    if (File(path).existsSync()) return Future.value(path);
    final key = (book.key, index);
    if (_running[key] case final running?) return running;
    final (_, c) = _waiting.remove(key) ?? (book.path, Completer<String?>());
    _waiting[key] = (book.path, c);
    while (_waiting.length > _maxWaiting) {
      _waiting.remove(_waiting.keys.first)!.$2.complete(null);
    }
    _pump();
    return c.future;
  }

  /// The tile showing [bookKey]'s page [index] is gone.
  void cancel(String bookKey, int index) => _waiting.remove((bookKey, index))?.$2.complete(null);

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

  Future<String?> _make(String bookPath, (String, int) key) async {
    final (bookKey, index) = key;
    final path = pathOf(bookKey, index);
    ComicDocument? doc;
    try {
      if (await File(path).exists()) return path;
      doc = await _open(bookPath);
      if (_closed || index >= doc.pageCount) return null;
      final jpeg = await thumbnailJpeg(doc, index, width);
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

final shufflePagesProvider = Provider<ShufflePages>((ref) {
  final s = ShufflePages(dir: '${ref.watch(coverDirProvider)}/pages');
  ref.onDispose(s.close);
  return s;
});

/// A book's tile picture in shuffle: its page [page], with the cover in its
/// place until that page is ready.
class ShuffledPage extends ConsumerStatefulWidget {
  const ShuffledPage({super.key, required this.book, required this.page, required this.cover});

  final LibraryBook book;
  final int page;

  /// What shows until the page is made, or when it cannot be.
  final Widget cover;

  @override
  ConsumerState<ShuffledPage> createState() => _ShuffledPageState();
}

class _ShuffledPageState extends ConsumerState<ShuffledPage> {
  String? _path;
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
    if (old.book.key != widget.book.key || old.page != widget.page) {
      _pages.cancel(old.book.key, old.page);
      _load();
    }
  }

  void _load() {
    final book = widget.book.key, page = widget.page;
    final known = _pages.pathOf(book, page);
    // A page made before shows at once, with no cover flashing first.
    _path = File(known).existsSync() ? known : null;
    if (_path != null) return;
    unawaited(
      _pages.get(widget.book, page).then((path) {
        if (mounted && path != null && widget.book.key == book && widget.page == page) setState(() => _path = path);
      }),
    );
  }

  @override
  void dispose() {
    _pages.cancel(widget.book.key, widget.page);
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
      cacheWidth: ShufflePages.width,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.cover,
    );
  }
}
