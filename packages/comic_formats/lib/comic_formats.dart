/// The format layer: the [ComicDocument] interface every source hides
/// behind, and its CBZ, CBT, EPUB, PDF and folder adapters.
library;

import 'src/document.dart';

export 'src/background.dart';
export 'src/book_info.dart';
export 'src/cbt.dart';
export 'src/cbz.dart';
export 'src/comic_info.dart' hide unescapeXml;
export 'src/content_key.dart';
export 'src/document.dart';
export 'src/epub.dart' hide parseOpfMetadata;
export 'src/file_name.dart';
export 'src/folder.dart';
export 'src/image_size.dart';
export 'src/natural_sort.dart';
export 'src/open.dart';
export 'src/pdf.dart';
export 'src/sniff.dart';
