import 'dart:math' as math;

import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/random_unread.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ga`: which comics count as unread, and that the pick is among them.
void main() {
  LibraryBook book(String key, {int? page, bool peek = false, bool? started, bool? completed, S3Shelf? s3}) =>
      LibraryBook(
        key: key,
        series: 'S',
        pageCount: 10,
        format: key == 'pdf' ? 'pdf' : 'cbz',
        path: '/c/$key',
        addedAt: DateTime(2026),
        page: page,
        peek: peek,
        startedMark: started,
        completedMark: completed,
        s3: s3,
      );

  final fresh = book('fresh');
  final peeked = book('peeked', page: 3, peek: true); // A look of seconds: still unread.
  final reading = book('reading', page: 3);
  final startedByHand = book('startedByHand', started: true);
  final done = book('done', completed: true);
  final remote = book('remote', s3: const S3Shelf(S3Mark.remote));
  final pdf = book('pdf');
  final all = [fresh, peeked, reading, startedByHand, done, remote, pdf];

  Set<String> picks({bool Function(LibraryBook)? shown, String? except}) => {
    for (var seed = 0; seed < 200; seed++)
      ?pickUnread(all, shown: shown ?? (_) => true, except: except, random: math.Random(seed))?.key,
  };

  test('unread is not completed and not being read; S3-only comics are left out', () {
    expect(picks(), {'fresh', 'peeked', 'pdf'});
  });

  test('the open comic is left out, so ga again brings another', () {
    expect(picks(except: 'fresh'), {'peeked', 'pdf'});
  });

  test("the library's filter decides what can be picked", () {
    expect(picks(shown: (b) => b.format == 'pdf'), {'pdf'});
  });

  test('copies of one comic count once', () {
    final twice = [fresh, fresh, fresh, pdf];
    final counts = <String, int>{};
    for (var seed = 0; seed < 2000; seed++) {
      final key = pickUnread(twice, shown: (_) => true, random: math.Random(seed))!.key;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    expect(counts['fresh']! / 2000, closeTo(0.5, 0.05));
  });

  test('nothing left gives null', () {
    expect(pickUnread([reading, done, remote], shown: (_) => true), isNull);
    expect(pickUnread([fresh], shown: (_) => true, except: 'fresh'), isNull);
  });
}
