import 'package:comicredr/src/library/folder_filter.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryBook book(String format, {int? size, DateTime? modified}) => LibraryBook(
  key: '$format-$size-$modified',
  series: 'S',
  seriesId: 1,
  pageCount: 1,
  format: format,
  path: '/c/$format',
  addedAt: DateTime(2020),
  size: size,
  modified: modified,
);

void main() {
  final now = DateTime(2026, 9, 27, 12);

  test('no filter lets everything through, even without a size or date', () {
    expect(FolderFilter.none.isActive, isFalse);
    expect(FolderFilter.none.accepts(book('cbz'), now), isTrue);
  });

  test('types: none picked is every type, else only those picked', () {
    final f = FolderFilter.none.toggle('pdf').toggle('folder');
    expect(f.accepts(book('pdf'), now), isTrue);
    expect(f.accepts(book('folder'), now), isTrue);
    expect(f.accepts(book('cbz'), now), isFalse);
    expect(f.toggle('pdf').toggle('folder'), FolderFilter.none);
  });

  test('size ranges meet without a gap, in MB as file managers count', () {
    const mb = 1000000;
    expect(SizeRange.under10.accepts(10 * mb - 1), isTrue);
    expect(SizeRange.under10.accepts(10 * mb), isFalse);
    expect(SizeRange.to50.accepts(10 * mb), isTrue);
    expect(SizeRange.to200.accepts(199 * mb), isTrue);
    expect(SizeRange.over200.accepts(200 * mb), isTrue);
    expect(SizeRange.over200.accepts(null), isFalse);
    for (final bytes in [0, 5 * mb, 10 * mb, 50 * mb, 200 * mb, 900 * mb]) {
      final hits = SizeRange.values.where((r) => r != SizeRange.any && r.accepts(bytes));
      expect(hits, hasLength(1), reason: '$bytes bytes');
    }
  });

  test('date ranges count back from now', () {
    DateTime ago(int days) => now.subtract(Duration(days: days));
    expect(DateRange.day.accepts(now.subtract(const Duration(hours: 23)), now), isTrue);
    expect(DateRange.day.accepts(ago(2), now), isFalse);
    expect(DateRange.week.accepts(ago(6), now), isTrue);
    expect(DateRange.month.accepts(ago(31), now), isFalse);
    expect(DateRange.year.accepts(ago(300), now), isTrue);
    expect(DateRange.older.accepts(ago(300), now), isFalse);
    expect(DateRange.older.accepts(ago(400), now), isTrue);
    expect(DateRange.week.accepts(null, now), isFalse);
  });

  test('the parts combine', () {
    const f = FolderFilter(formats: {'cbz'}, size: SizeRange.to50, date: DateRange.week);
    final fresh = now.subtract(const Duration(days: 1));
    expect(f.accepts(book('cbz', size: 20000000, modified: fresh), now), isTrue);
    expect(f.accepts(book('pdf', size: 20000000, modified: fresh), now), isFalse);
    expect(f.accepts(book('cbz', size: 2000000, modified: fresh), now), isFalse);
    expect(f.accepts(book('cbz', size: 20000000, modified: DateTime(2020)), now), isFalse);
  });

  test('saved and read back; nothing filtered saves nothing; junk reads as no filter', () {
    const f = FolderFilter(formats: {'pdf', 'cbz'}, size: SizeRange.over200, date: DateRange.older);
    expect(FolderFilter.decode(f.encode()), f);
    expect(FolderFilter.none.encode(), isNull);
    expect(FolderFilter.decode(null), FolderFilter.none);
    expect(FolderFilter.decode('not json'), FolderFilter.none);
    expect(FolderFilter.decode('{"size": "huge", "formats": [1, "pdf"]}'), const FolderFilter(formats: {"pdf"}));
  });
}
