import 'dart:io';
import 'dart:typed_data';

import 'document.dart';
import 'image_size.dart';
import 'page_facts.dart';

/// The [ComicDocument] pages of a book whose pages are image files as
/// stored, in a ZIP, a tar, a folder or a single image file: a page is its
/// stored bytes, and its size and facts come from its header, read whole
/// only when a JPEG's frame header lies past the first [headBytes].
mixin StoredPages implements ComicDocument {
  /// Page [index]'s stored bytes.
  Future<Uint8List> storedPage(int index);

  /// The first [n] bytes of page [index], or all of it when it is shorter.
  Future<Uint8List> storedHead(int index, int n);

  /// How many bytes page [index] takes as stored.
  Future<int> storedLength(int index);

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async =>
      PageImage(await storedPage(index));

  @override
  Future<Uint8List?> rawPage(int index) => storedPage(index);

  @override
  Future<List<(int, int)?>> pageSizes() async => [
    for (final f in await pageFacts())
      if (f.width case final w?) (w, f.height!) else null,
  ];

  @override
  Future<List<PageFacts>> pageFacts() async => [for (var i = 0; i < pageCount; i++) await _facts(i)];

  Future<PageFacts> _facts(int index) async {
    final int total;
    final PageFacts head;
    try {
      total = await storedLength(index);
      head = imageFacts(await storedHead(index, headBytes), total: total);
    } on Exception {
      return PageFacts.unknown;
    }
    if (head.width != null || total <= headBytes) return head;
    try {
      return imageFacts(await storedPage(index), total: total);
    } on Exception {
      return head;
    }
  }
}

/// The first [n] bytes of [file], or all of it when it is shorter.
Future<Uint8List> readFileHead(File file, int n) async {
  final f = await file.open();
  try {
    return await f.read(n);
  } finally {
    await f.close();
  }
}
