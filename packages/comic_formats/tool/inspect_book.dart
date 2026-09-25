/// Prints what the format layer makes of each book given: its kind, page
/// count, first pages, what the pages are stored as, and metadata, or why
/// it was refused.
///
///     dart run tool/inspect_book.dart book.cbt book.epub folder/
// ignore_for_file: avoid_print
library;

import 'package:comic_formats/comic_formats.dart';

Future<void> main(List<String> args) async {
  for (final path in args) {
    try {
      final doc = await openDocument(path);
      final names = switch (doc) {
        CbzDocument d => d.pageNames,
        CbtDocument d => d.pageNames,
        EpubDocument d => d.pageNames,
        FolderDocument d => d.pageNames,
        _ => const <String>[],
      };
      final m = await doc.embeddedMetadata();
      print('$path: ${bookKind(path).name}, ${doc.pageCount} pages');
      if (names.isNotEmpty) print('  pages: ${names.take(4).join(', ')}${names.length > 4 ? ', ...' : ''}');
      final sw = Stopwatch()..start();
      final facts = await doc.pageFacts();
      final formats = <String, int>{};
      for (final f in facts) {
        formats[f.format] = (formats[f.format] ?? 0) + 1;
      }
      final q = [
        for (final f in facts)
          if (f.quality != null) f.quality!,
      ]..sort();
      final first = facts.first;
      print(
        '  page facts in ${sw.elapsedMilliseconds} ms: $formats, first ${first.width} x ${first.height}'
        '${q.isEmpty ? '' : ', JPEG quality ${q.first} to ${q.last}'}',
      );
      if (bookKind(path) == BookKind.pdf) {
        sw.reset();
        final images = pdfImages(path);
        print(
          '  PDF images in ${sw.elapsedMilliseconds} ms: ${images.length}, first '
          '${images.isEmpty ? '-' : '${images.first.width} x ${images.first.height} ${images.first.filter} q${images.first.quality}'}',
        );
      }
      if (m != null) {
        print(
          '  title: ${m.title}, series: ${m.series} #${m.number}, year: ${m.year}, cover page: ${m.frontCoverPage}',
        );
        print('  writers: ${m.writers}, artists: ${m.artists}, right to left: ${m.rightToLeft}');
      }
      await doc.close();
    } on FormatException catch (e) {
      print('$path: refused: ${e.message}');
    }
  }
}
