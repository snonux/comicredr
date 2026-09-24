import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/settings_store.dart';
import 'library_store.dart';

/// The folder the library starts with: `~/Comics` on the laptop, the
/// Comics folder in the phone's shared storage on Android. Null when there
/// is no home to look in.
String? defaultComicsFolder({Map<String, String>? environment, bool? android}) {
  if (android ?? Platform.isAndroid) return '/storage/emulated/0/Comics';
  final home = (environment ?? Platform.environment)['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, 'Comics');
}

/// Adds [folder] to the library when nobody has set the library up yet: no
/// library folder at all, [folder] exists, and it was never taken out of
/// the library. Otherwise the library stays as it is, as if there were no
/// default. Runs at every start, so a Comics folder made later is picked
/// up then. Returns whether it added the folder.
Future<bool> addDefaultFolder(LibraryStore library, SettingsStore settings, String? folder) async {
  if (folder == null) return false;
  folder = p.normalize(p.absolute(folder));
  if ((await library.roots()).isNotEmpty) return false;
  if (await settings.loadBool(SettingsStore.defaultFolderRemoved) ?? false) return false;
  if (!await Directory(folder).exists()) return false;
  await library.addRoot(folder);
  return true;
}

/// Takes library folder [id] at [path] out of the library. Taking out the
/// default folder is remembered, so the next start doesn't put it back.
Future<void> removeLibraryFolder(
  LibraryStore library,
  SettingsStore settings,
  int id,
  String path, {
  String? defaultFolder,
}) async {
  final folder = defaultFolder ?? defaultComicsFolder();
  if (folder != null && p.equals(p.normalize(p.absolute(folder)), path)) {
    await settings.saveBool(SettingsStore.defaultFolderRemoved, true);
  }
  await library.removeRoot(id);
}
