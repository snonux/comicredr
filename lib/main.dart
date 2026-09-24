import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/library/providers.dart';

/// `comicredr [book]` opens the book straight away.
/// `comicredr --add-root ~/Comics` adds a folder to the library first.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final roots = <String>[];
  String? book;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--add-root' && i + 1 < args.length) {
      roots.add(args[++i]);
    } else {
      book ??= args[i];
    }
  }
  final cache = await getApplicationCacheDirectory();
  runApp(
    ProviderScope(
      overrides: [coverDirProvider.overrideWithValue('${cache.path}/covers')],
      child: ComicRedrApp(initialPath: book, addRoots: roots),
    ),
  );
}
