import 'dart:async';
import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/reader/page_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// A document served like the shared PDF worker: one request at a time,
/// newest first, and only when the test says so.
class LifoDoc implements ComicDocument {
  final queue = <(int, Completer<PageImage>)>[];
  final served = <int>[];

  @override
  int get pageCount => 10;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) {
    final c = Completer<PageImage>();
    queue.add((index, c));
    return c.future;
  }

  /// Serves the newest waiting request.
  void serveOne() {
    final (index, c) = queue.removeLast();
    served.add(index);
    c.complete(PageImage(Uint8List.fromList([index, 0, 0, 255]), width: 1, height: 1, bgra: true));
  }

  @override
  Future<Uint8List?> rawPage(int index) async => null;
  @override
  Future<ComicMeta?> embeddedMetadata() async => null;
  @override
  Future<void> close() async {}
}

/// Pages [width] px wide and half as tall again, served at once.
class SmallDoc implements ComicDocument {
  SmallDoc(this.width);

  final int width;

  @override
  int get pageCount => 3;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async {
    final h = width * 3 ~/ 2;
    final bytes = Uint8List(width * h * 4);
    for (var p = 0; p < bytes.length; p += 4) {
      bytes.setAll(p, [p % 7 * 30, 120, 200, 255]);
    }
    return PageImage(bytes, width: width, height: h, bgra: true);
  }

  @override
  Future<Uint8List?> rawPage(int index) async => null;
  @override
  Future<ComicMeta?> embeddedMetadata() async => null;
  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('clean-up enlarges a page narrower than the screen, at most twice, and keeps both', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(SmallDoc(100), budgetBytes: 64 << 20);
      final plain = await cache.get(0, 512);
      final sharp = await cache.get(0, 512, sharpen: true);
      expect((plain.width, plain.height), (100, 150));
      expect((sharp.width, sharp.height), (200, 300));
      expect(cache.bytes, 100 * 150 * 4 + 200 * 300 * 4);
      plain.dispose();
      sharp.dispose();
      cache.dispose();
    });
  });

  testWidgets('clean-up leaves a page as wide as the screen as it is', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(SmallDoc(480), budgetBytes: 64 << 20);
      final sharp = await cache.get(0, 512, sharpen: true);
      expect(sharp.width, 480, reason: '512 / 480 is too little to be worth it');
      sharp.dispose();
      cache.dispose();
    });
  });

  testWidgets('a page turned to is not stuck behind the requests queued after its prefetch', (tester) async {
    await tester.runAsync(() async {
      final doc = LifoDoc();
      final cache = PageCache(doc, budgetBytes: 1 << 20);
      // The reader showed page 3 and warmed 4, 5 and 2; then detection
      // asked for pages of its own, newer than the prefetches.
      cache.prefetch([3, 4, 1], 512);
      unawaited(doc.page(7, targetWidth: 1024, targetHeight: 1024));
      unawaited(doc.page(8, targetWidth: 1024, targetHeight: 1024));
      // Now the reader turns to page 4.
      final shown = cache.get(3, 512);
      await Future<void>.delayed(Duration.zero);
      doc.serveOne();
      final image = await shown.timeout(const Duration(seconds: 2));
      expect(doc.served, [3], reason: 'the page on screen goes first');
      image.dispose();
      // The prefetch it overtook still lands, once, in the cache.
      while (doc.queue.isNotEmpty) {
        doc.serveOne();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(cache.bytes, 4 * 3, reason: 'pages 4, 5 and 2, each once');
      (await cache.get(3, 512)).dispose();
      expect(doc.served.where((p) => p == 3), hasLength(2));
      cache.dispose();
    });
  });
}
