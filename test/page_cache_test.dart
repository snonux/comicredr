import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/reader/page_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// A document served like the shared PDF worker: one request at a time,
/// newest first, and only when the test says so.
class LifoDoc implements ComicDocument {
  final queue = <(int, Completer<PageImage>)>[];
  final served = <int>[];

  @override
  int get pageCount => 10;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) {
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

/// A book of stored images, like a CBZ: every page is [bytes] as stored.
class StoredDoc implements ComicDocument {
  StoredDoc(this.bytes);

  final Uint8List bytes;
  var reads = 0;

  @override
  int get pageCount => 3;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async {
    reads++;
    return PageImage(bytes);
  }

  @override
  Future<Uint8List?> rawPage(int index) async => bytes;
  @override
  Future<ComicMeta?> embeddedMetadata() async => null;
  @override
  Future<void> close() async {}
}

/// A 400 x 600 page, black on the left half and white on the right.
Uint8List halfBlackPage() {
  final px = Uint8List(400 * 600);
  for (var y = 0; y < 600; y++) {
    px.fillRange(y * 400 + 200, y * 400 + 400, 255);
  }
  return encodeGrayPng(400, 600, px);
}

void main() {
  testWidgets('clean-up enlarges a page smaller than its box, at most twice, and keeps both', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(StoredDoc(halfBlackPage()), budgetBytes: 64 << 20);
      Future<(int, int)> size(Box box, {bool sharpen = false}) async {
        final image = await cache.get(0, box, sharpen: sharpen);
        final s = (image.width, image.height);
        image.dispose();
        return s;
      }

      expect(await size((width: 2000, height: 2000)), (400, 600));
      expect(await size((width: 2000, height: 2000), sharpen: true), (800, 1200), reason: 'twice, no more');
      expect(await size((width: 512, height: 768), sharpen: true), (512, 768));
      expect(await size((width: 448, height: 640), sharpen: true), (400, 600), reason: 'too little to be worth it');
      expect(cache.bytes, 400 * 600 * 4 + 800 * 1200 * 4 + 512 * 768 * 4 + 400 * 600 * 4);
      cache.dispose();
    });
  });

  testWidgets('clean-up enlarges a zoomed-in tile past the stored page', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(StoredDoc(halfBlackPage()), budgetBytes: 64 << 20);
      const middle = (left: 0.25, top: 0.25, width: 0.5, height: 0.5);
      final plain = await cache.tile(0, 1600, middle);
      final sharp = await cache.tile(0, 1600, middle, sharpen: true);
      expect((plain.image.width, plain.image.height), (200, 300));
      expect((sharp.image.width, sharp.image.height), (400, 600));
      expect(sharp.region, plain.region);
      plain.image.dispose();
      sharp.image.dispose();
      cache.dispose();
    });
  });

  testWidgets('a stored page decodes to fit the box it is shown in, never larger than stored', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(StoredDoc(halfBlackPage()), budgetBytes: 64 << 20);
      Future<(int, int)> size(Box box) async {
        final image = await cache.get(0, box);
        final s = (image.width, image.height);
        image.dispose();
        return s;
      }

      // Boxes round up to 64 px steps: fit-page on a small screen.
      expect(await size((width: 200, height: 200)), (171, 256));
      // Fit-width leaves the height free.
      expect(await size((width: 256, height: 0)), (256, 384));
      expect(await size((width: 2000, height: 2000)), (400, 600));
      expect(cache.bytes, 171 * 256 * 4 + 256 * 384 * 4 + 400 * 600 * 4);
      cache.dispose();
    });
  });

  testWidgets('a tile keeps only the part of the page asked for, at the scale asked for', (tester) async {
    await tester.runAsync(() async {
      final cache = PageCache(StoredDoc(halfBlackPage()), budgetBytes: 64 << 20);
      const region = (left: 0.25, top: 0.5, width: 0.5, height: 0.5);
      final tile = await cache.tile(0, 400, region);
      expect((tile.image.width, tile.image.height), (200, 300));
      expect(tile.region, region);
      expect(cache.bytes, 200 * 300 * 4, reason: 'the whole decoded page is not kept');
      final data = (await tile.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int grey(int x, int y) => data.getUint8((y * 200 + x) * 4);
      expect(grey(10, 10), 0, reason: 'the black half');
      expect(grey(190, 290), 255, reason: 'the white half');
      tile.image.dispose();
      // A stored image is never scaled up: asked for twice its size, the
      // tile is at its own.
      final big = await cache.tile(0, 800, region);
      expect((big.image.width, big.image.height), (200, 300));
      big.image.dispose();
      cache.dispose();
    });
  });

  testWidgets('under memory pressure only the pages on screen stay', (tester) async {
    await tester.runAsync(() async {
      final doc = StoredDoc(halfBlackPage());
      final cache = PageCache(doc, budgetBytes: 64 << 20);
      const box = (width: 256, height: 0);
      for (final i in [0, 1, 2]) {
        (await cache.get(i, box)).dispose();
      }
      (await cache.tile(1, 400, (left: 0, top: 0, width: 1, height: 0.5))).image.dispose();
      cache.shed({1});
      expect(cache.bytes, 256 * 384 * 4 + 400 * 300 * 4);
      final reads = doc.reads;
      (await cache.get(1, box)).dispose();
      expect(doc.reads, reads, reason: 'the page on screen is still cached');
      (await cache.get(0, box)).dispose();
      expect(doc.reads, reads + 1);
      cache.dispose();
    });
  });

  test('the page budget is a slice of the device memory', () {
    const mb = 1 << 20, gb = 1 << 30;
    expect(pageBudgetBytes(phone: true, memTotal: 12 * gb), 80 * mb);
    expect(pageBudgetBytes(phone: true, memTotal: 8 * gb), 64 * mb);
    expect(pageBudgetBytes(phone: true, memTotal: 3 * gb), 40 * mb);
    expect(pageBudgetBytes(phone: true), 48 * mb);
    expect(pageBudgetBytes(phone: false, memTotal: 32 * gb), 512 * mb);
    expect(pageBudgetBytes(phone: false, memTotal: 8 * gb), 128 * mb);
    expect(readMemTotal(), greaterThan(0));
  });

  testWidgets('a page turned to is not stuck behind the requests queued after its prefetch', (tester) async {
    await tester.runAsync(() async {
      final doc = LifoDoc();
      final cache = PageCache(doc, budgetBytes: 1 << 20);
      const box = (width: 512, height: 512);
      // The reader showed page 3 and warmed 4, 5 and 2; then detection
      // asked for pages of its own, newer than the prefetches.
      cache.prefetch([3, 4, 1], box);
      unawaited(doc.page(7, targetWidth: 1024, targetHeight: 1024));
      unawaited(doc.page(8, targetWidth: 1024, targetHeight: 1024));
      // Now the reader turns to page 4.
      final shown = cache.get(3, box);
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
      (await cache.get(3, box)).dispose();
      expect(doc.served.where((p) => p == 3), hasLength(2));
      cache.dispose();
    });
  });
}
