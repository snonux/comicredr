import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../reader/reader_notifier.dart';
import 'library_store.dart';
import 'scanner.dart';

/// Where covers go: `<cache>/covers`, set at startup from the platform's
/// cache directory. Always safe to delete; a rescan puts them back.
final coverDirProvider = Provider<String>((ref) => '${Directory.systemTemp.path}/comicredr-covers');

final libraryStoreProvider = Provider<LibraryStore>((ref) => LibraryStore(ref.watch(databaseProvider)));

final scannerProvider = Provider<LibraryScanner>((ref) {
  final sidecars = ref.watch(sidecarSyncProvider);
  final scanner = LibraryScanner(
    ref.watch(libraryStoreProvider),
    coverDir: ref.watch(coverDirProvider),
    onBookRead: (path, key, {required folder}) => sidecars.attach(path, key, folder: folder),
  );
  ref.onDispose(scanner.dispose);
  return scanner;
});

final scanStatusProvider = StreamProvider<ScanStatus>((ref) => ref.watch(scannerProvider).status);

final booksProvider = StreamProvider<List<LibraryBook>>((ref) => ref.watch(libraryStoreProvider).watchBooks());

final rootsProvider = StreamProvider<List<RootInfo>>((ref) => ref.watch(libraryStoreProvider).watchRoots());

final bookmarksProvider = StreamProvider.family<List<BookmarkInfo>, String>(
  (ref, key) => ref.watch(libraryStoreProvider).watchBookmarks(key),
);
