import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/data/data_dirs.dart';
import 'src/input/keys_file.dart';
import 'src/library/providers.dart';
import 'src/providers.dart';

/// `comicredr [book]` opens the book straight away; `comicredr folder`
/// shows a folder of comics on the library's Folders tab.
/// `comicredr --add-root ~/Comics` adds a folder to the library first.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The GPU keeps textures the app has let go of, for reuse, up to about a
  // dozen screenfuls. Pages decode at screen size and zoom with tiles of
  // many sizes, which would mostly fill that with old tiles, so on the
  // phone the cache is kept small. Engines without Skia ignore this.
  if (defaultTargetPlatform == TargetPlatform.android) {
    unawaited(
      SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', 24 << 20).catchError((Object _) {}),
    );
  }
  final roots = <String>[];
  String? book;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--add-root' && i + 1 < args.length) {
      roots.add(args[++i]);
    } else {
      book ??= args[i];
    }
  }
  // ~/Comics/.comicredr or the usual XDG folders; see appDirs.
  final dirs = await appDirs();
  await Directory(dirs.data).create(recursive: true);
  final cache = await Directory(dirs.cache).create(recursive: true);
  final keys = await loadKeymap();
  runApp(
    ProviderScope(
      overrides: [
        coverDirProvider.overrideWithValue('${cache.path}/covers'),
        startKeymapProvider.overrideWithValue(keys),
        appDataDirProvider.overrideWithValue(dirs.data),
      ],
      child: ComicRedrApp(initialPath: book, addRoots: roots),
    ),
  );
}
