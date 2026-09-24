/// How pages are laid out on screen. Continuous scroll and guided view join
/// in later milestones; `v` and `Tab` already know about them.
enum PageMode { single, spread }

/// The pages shown together at [page]: one in single mode, up to two in a
/// spread. With [coverAlone] the first page stands by itself and spreads
/// pair 1-2, 3-4, …; `Shift+d` flips it for books whose pairing is off by one.
List<int> unitAt(int page, int pageCount, PageMode mode, {bool coverAlone = true}) {
  if (mode == PageMode.single || pageCount < 2) return [page];
  final offset = coverAlone ? 1 : 0;
  if (coverAlone && page == 0) return [0];
  final first = page - ((page - offset) % 2);
  return [first, if (first + 1 < pageCount) first + 1];
}

/// The first page of the unit [steps] units away from the one holding
/// [page], clamped to the book.
int stepFrom(int page, int steps, int pageCount, PageMode mode, {bool coverAlone = true}) {
  var current = unitAt(page, pageCount, mode, coverAlone: coverAlone);
  for (var i = 0; i < steps.abs(); i++) {
    final next = steps > 0 ? current.last + 1 : current.first - 1;
    if (next < 0 || next >= pageCount) break;
    current = unitAt(next, pageCount, mode, coverAlone: coverAlone);
  }
  return current.first;
}
