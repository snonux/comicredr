import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:test/test.dart';

void main() {
  group('sniffFormat', () {
    Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

    test('recognises ZIP, RAR and PDF by content', () {
      expect(sniffFormat(bytes('PK\x03\x04rest')), SourceFormat.zip);
      expect(sniffFormat(bytes('Rar!\x1a\x07\x00')), SourceFormat.rar);
      expect(sniffFormat(bytes('%PDF-1.7')), SourceFormat.pdf);
    });

    test('unknown or short input is unknown', () {
      expect(sniffFormat(bytes('GIF89a')), SourceFormat.unknown);
      expect(sniffFormat(bytes('PK')), SourceFormat.unknown);
    });
  });

  group('naturalCompare', () {
    test('orders numbers by value', () {
      final names = ['page10.jpg', 'page2.jpg', 'Page1.jpg', 'page02b.jpg'];
      names.sort(naturalCompare);
      expect(names, ['Page1.jpg', 'page2.jpg', 'page02b.jpg', 'page10.jpg']);
    });

    test('nested folders sort by path', () {
      final names = ['b/1.jpg', 'a/10.jpg', 'a/9.jpg'];
      names.sort(naturalCompare);
      expect(names, ['a/9.jpg', 'a/10.jpg', 'b/1.jpg']);
    });
  });

  group('isPageEntry', () {
    test('keeps images, skips junk', () {
      expect(isPageEntry('Book/001.JPG'), isTrue);
      expect(isPageEntry('p.webp'), isTrue);
      expect(isPageEntry('__MACOSX/Book/._001.jpg'), isFalse);
      expect(isPageEntry('Book/.hidden.png'), isFalse);
      expect(isPageEntry('Thumbs.db'), isFalse);
      expect(isPageEntry('ComicInfo.xml'), isFalse);
      expect(isPageEntry('README.txt'), isFalse);
      expect(isPageEntry('Book/'), isFalse);
    });
  });
}
