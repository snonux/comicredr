import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:comic_formats/src/comic_info.dart' show unescapeXml;
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

    test('a folder sorts before one whose name continues it', () {
      final names = ['Issue 1 Bonus/01.jpg', 'Issue 1/02.jpg', 'ch1-5/01.jpg', 'Issue 1/01.jpg', 'ch1/01.jpg'];
      names.sort(naturalCompare);
      expect(names, ['ch1/01.jpg', 'ch1-5/01.jpg', 'Issue 1/01.jpg', 'Issue 1/02.jpg', 'Issue 1 Bonus/01.jpg']);
    });

    test('numbers too long for an int still sort by value', () {
      final names = ['p100000000000000000000', 'p5', 'p99999999999999999999'];
      names.sort(naturalCompare);
      expect(names, ['p5', 'p99999999999999999999', 'p100000000000000000000']);
    });
  });

  group('unescapeXml', () {
    test('keeps a numeric reference that names no character as written', () {
      expect(unescapeXml('bad &#99999999; ref &#x110000; &amp; &#65;'), 'bad &#99999999; ref &#x110000; & A');
      expect(unescapeXml('&#99999999999999999999999;'), '&#99999999999999999999999;');
    });

    test('a ComicInfo with a bad reference still gives its fields', () {
      final meta = parseComicInfo(
        '<ComicInfo><Series>X</Series><Summary>bad &#99999999; ref</Summary>'
        '<Pages><Page Image="99999999999999999999" Type="FrontCover"/></Pages></ComicInfo>',
      );
      expect(meta.series, 'X');
      expect(meta.summary, 'bad &#99999999; ref');
      expect(meta.frontCoverPage, isNull);
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
