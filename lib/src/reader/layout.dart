/// How pages are laid out on screen outside guided view, which is a flag on
/// top of this so `v` can return to it. Continuous scroll joins later.
enum PageMode { single, spread }

/// Whether a page [width] x [height] is wide enough to be a scanned
/// two-page spread, which stands alone in spread mode. A little wider than
/// square, so a square page still pairs.
bool isWidePage(num width, num height) => height > 0 && width >= height * 1.1;

/// The pages shown together at [page]: one in single mode, up to two in a
/// spread. With [coverAlone] the first page stands by itself and spreads
/// pair 1-2, 3-4, …; `Shift+d` flips it for books whose pairing is off by one.
///
/// A page in [wide] is a double-page scan: it stands alone, and pairing
/// starts again after it, so the pages that follow keep their sides. The
/// page before it stands alone too when it would otherwise pair with it.
List<int> unitAt(int page, int pageCount, PageMode mode, {bool coverAlone = true, Set<int> wide = const {}}) {
  if (mode == PageMode.single || pageCount < 2) return [page];
  if (wide.isEmpty) {
    final offset = coverAlone ? 1 : 0;
    if (coverAlone && page == 0) return [0];
    final first = page - ((page - offset) % 2);
    return [first, if (first + 1 < pageCount) first + 1];
  }
  // Walk the book from the start: a wide page changes the pairing of every
  // page after it. Books are a few hundred pages, so this is cheap.
  var first = 0;
  while (true) {
    final alone =
        (coverAlone && first == 0) || wide.contains(first) || first + 1 >= pageCount || wide.contains(first + 1);
    final last = alone ? first : first + 1;
    if (page <= last) return [first, if (!alone) first + 1];
    first = last + 1;
  }
}

/// The first page of the unit [steps] units away from the one holding
/// [page], clamped to the book.
int stepFrom(int page, int steps, int pageCount, PageMode mode, {bool coverAlone = true, Set<int> wide = const {}}) {
  var current = unitAt(page, pageCount, mode, coverAlone: coverAlone, wide: wide);
  for (var i = 0; i < steps.abs(); i++) {
    final next = steps > 0 ? current.last + 1 : current.first - 1;
    if (next < 0 || next >= pageCount) break;
    current = unitAt(next, pageCount, mode, coverAlone: coverAlone, wide: wide);
  }
  return current.first;
}
