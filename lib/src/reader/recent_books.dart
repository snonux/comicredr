import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import '../library/providers.dart';
import 'open_book.dart';
import 'reader_providers.dart';

/// A comic the reader opened: where it was, its content key (which finds
/// it again in the library if it moved) and its title for the button.
typedef RecentBook = ({String path, String key, String title});

/// What `C` finds: the book, and the path to open it at now, null when it
/// is gone from where it was and the library has no other copy.
typedef RecentPick = ({RecentBook book, String? path});

final recentBooksProvider = NotifierProvider<RecentBooks, List<RecentBook>>(RecentBooks.new);

/// The comics opened last, newest first, kept in the settings table
/// ([SettingsStore.recentBooks]) so `C` and the library's Continue button
/// reopen the last one after a restart. Its position comes back the way
/// any reopened book's does, from the progress row and the sidecar.
class RecentBooks extends Notifier<List<RecentBook>> {
  /// Enough to step back past a couple of comics that have gone.
  static const kept = 5;

  late Future<void> _loaded;

  SettingsStore get _settings => ref.read(settingsStoreProvider);

  @override
  List<RecentBook> build() {
    _loaded = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final v = await _settings.loadJson(SettingsStore.recentBooks);
      if (v is! List || !ref.mounted) return;
      state = [
        for (final e in v)
          if (e case {'path': final String path, 'key': final String key})
            (path: path, key: key, title: e['title'] is String ? e['title'] as String : path),
      ];
    } catch (e) {
      debugPrint('Could not read the recent comics: $e');
    }
  }

  /// [book] was just opened: it goes first.
  Future<void> opened(OpenBook book) async {
    await _loaded;
    if (!ref.mounted) return;
    await _set([
      (path: book.path, key: book.key, title: book.title),
      ...state.where((b) => b.key != book.key && b.path != book.path),
    ]);
  }

  /// Takes [key] off the list: the comic was deleted, or is gone.
  Future<void> forget(String key) async {
    await _loaded;
    if (!ref.mounted || !state.any((b) => b.key == key)) return;
    await _set(state.where((b) => b.key != key).toList());
  }

  Future<void> _set(List<RecentBook> books) async {
    state = books.take(kept).toList();
    try {
      await _settings.saveJson(SettingsStore.recentBooks, [
        for (final b in state) {'path': b.path, 'key': b.key, 'title': b.title},
      ]);
    } catch (e) {
      debugPrint('Could not save the recent comics: $e');
    }
  }

  /// The comic to continue: the one opened last, or with [except] (the key
  /// of the comic open now) the last one before it. Null when there is none.
  /// A comic moved within the library is found by its content key.
  Future<RecentPick?> pick({String? except}) async {
    await _loaded;
    final book = state.where((b) => b.key != except).firstOrNull;
    if (book == null) return null;
    if (await _exists(book.path)) return (book: book, path: book.path);
    try {
      for (final b in await ref.read(libraryStoreProvider).books()) {
        if (b.key == book.key && await _exists(b.path)) return (book: book, path: b.path);
      }
    } catch (e) {
      debugPrint('Could not look for a moved comic: $e');
    }
    return (book: book, path: null);
  }

  static Future<bool> _exists(String path) async => await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
}
