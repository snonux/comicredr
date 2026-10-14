/// Compares names the way a person would: `page2` before `page10`, case
/// ignored. Used to order archive entries and folder images, and the
/// library's comics by path. Paths compare folder by folder, so `Issue 1/`
/// comes before `Issue 1 Bonus/`. Each name is cut into runs of digits and
/// runs of anything else; digit runs compare by value, the rest by code
/// unit.
///
/// Sorting a library of thousands of comics calls this some hundred
/// thousand times on the UI isolate, so it walks the two strings in place
/// and makes no lists, substrings or regular expressions.
int naturalCompare(String a, String b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  var i = 0, j = 0;
  while (true) {
    final ea = _end(a, i), eb = _end(b, j);
    final c = _compareName(a, i, ea, b, j, eb);
    if (c != 0) return c;
    final moreA = ea < a.length, moreB = eb < b.length;
    if (!moreA || !moreB) return moreA == moreB ? 0 : (moreA ? 1 : -1);
    i = ea + 1;
    j = eb + 1;
  }
}

/// Where the path component starting at [from] ends: the next `/` or the end.
int _end(String s, int from) {
  final at = s.indexOf('/', from);
  return at < 0 ? s.length : at;
}

bool _digit(int c) => c >= 0x30 && c <= 0x39;

/// End of the run of digits, or of non-digits, starting at [from] (< [end]).
int _runEnd(String s, int from, int end) {
  final digits = _digit(s.codeUnitAt(from));
  var k = from + 1;
  while (k < end && _digit(s.codeUnitAt(k)) == digits) {
    k++;
  }
  return k;
}

int _compareName(String a, int i, int ea, String b, int j, int eb) {
  while (i < ea && j < eb) {
    final ra = _runEnd(a, i, ea), rb = _runEnd(b, j, eb);
    final c = _digit(a.codeUnitAt(i)) && _digit(b.codeUnitAt(j))
        ? _compareNumbers(a, i, ra, b, j, rb)
        : _compareRuns(a, i, ra, b, j, rb);
    if (c != 0) return c;
    i = ra;
    j = rb;
  }
  // The one with runs left over is the longer.
  return (i < ea ? 1 : 0) - (j < eb ? 1 : 0);
}

/// The runs as strings would compare: code unit by code unit, a prefix first.
int _compareRuns(String a, int i, int ea, String b, int j, int eb) {
  while (i < ea && j < eb) {
    final c = a.codeUnitAt(i) - b.codeUnitAt(j);
    if (c != 0) return c < 0 ? -1 : 1;
    i++;
    j++;
  }
  return (ea - i).compareTo(eb - j);
}

/// Digit runs by value, however long; `01` after `1` when the values tie.
int _compareNumbers(String a, int i, int ea, String b, int j, int eb) {
  var za = i, zb = j;
  while (za < ea && a.codeUnitAt(za) == 0x30) {
    za++;
  }
  while (zb < eb && b.codeUnitAt(zb) == 0x30) {
    zb++;
  }
  if (ea - za != eb - zb) return (ea - za).compareTo(eb - zb);
  final c = _compareRuns(a, za, ea, b, zb, eb);
  return c != 0 ? c : (ea - i).compareTo(eb - j);
}

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// Whether an archive entry or folder file is a page, skipping the junk
/// archives collect: `__MACOSX/`, dotfiles, `Thumbs.db`, and non-images.
bool isPageEntry(String path) {
  final normal = path.replaceAll('\\', '/');
  if (normal.contains('__MACOSX/')) return false;
  final name = normal.split('/').last;
  if (name.isEmpty || name.startsWith('.')) return false;
  final dot = name.lastIndexOf('.');
  return dot > 0 && _imageExtensions.contains(name.substring(dot).toLowerCase());
}
