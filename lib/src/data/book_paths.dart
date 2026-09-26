import 'package:path/path.dart' as p;

/// Where a book in the library is: [root], a library folder, joined with
/// its path inside it; a root that is itself a folder book has an empty
/// [relPath].
String bookPath(String root, String relPath) => relPath.isEmpty ? root : p.join(root, relPath);

/// A book's cover in the cover folder [coverDir] (`<cache>/covers`), named
/// after its content key.
String coverFile(String coverDir, String contentKey) => p.join(coverDir, '$contentKey.jpg');

/// The folder of a book's page thumbnails, which the page grid, the
/// progress bar's preview and shuffled covers share:
/// `<cache>/covers/pages/<content key>/`.
String pageThumbDir(String coverDir, String contentKey) => p.join(pageThumbsRoot(coverDir), contentKey);

/// The folder holding every book's [pageThumbDir].
String pageThumbsRoot(String coverDir) => p.join(coverDir, 'pages');
