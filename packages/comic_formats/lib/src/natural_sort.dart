/// Compares names the way a person would: `page2` before `page10`, case
/// ignored. Used to order archive entries and folder images.
int naturalCompare(String a, String b) {
  final ta = _tokens(a.toLowerCase());
  final tb = _tokens(b.toLowerCase());
  for (var i = 0; i < ta.length && i < tb.length; i++) {
    final x = ta[i], y = tb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null)
        ? (nx != ny ? nx.compareTo(ny) : x.length.compareTo(y.length))
        : x.compareTo(y);
    if (c != 0) return c;
  }
  return ta.length.compareTo(tb.length);
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
