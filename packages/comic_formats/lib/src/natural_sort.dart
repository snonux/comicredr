/// Compares names the way a person would: `page2` before `page10`, case
/// ignored. Used to order archive entries and folder images. Paths compare
/// folder by folder, so `Issue 1/` comes before `Issue 1 Bonus/`.
int naturalCompare(String a, String b) {
  final pa = a.toLowerCase().split('/');
  final pb = b.toLowerCase().split('/');
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final c = _compareName(pa[i], pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

int _compareName(String a, String b) {
  final ta = _tokens(a);
  final tb = _tokens(b);
  for (var i = 0; i < ta.length && i < tb.length; i++) {
    final x = ta[i], y = tb[i];
    final c = (_isDigits(x) && _isDigits(y)) ? _compareNumbers(x, y) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ta.length.compareTo(tb.length);
}

bool _isDigits(String s) => s.codeUnitAt(0) >= 48 && s.codeUnitAt(0) <= 57;

/// Digit runs by value, however long; `01` after `1` when the values tie.
int _compareNumbers(String x, String y) {
  final sx = x.replaceFirst(RegExp(r'^0+'), ''), sy = y.replaceFirst(RegExp(r'^0+'), '');
  if (sx.length != sy.length) return sx.length.compareTo(sy.length);
  final c = sx.compareTo(sy);
  return c != 0 ? c : x.length.compareTo(y.length);
}

final _digitsOrNot = RegExp(r'\d+|\D+');

List<String> _tokens(String s) => [for (final m in _digitsOrNot.allMatches(s)) m[0]!];

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
