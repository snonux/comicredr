import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/data_dirs.dart';
import '../data/settings_store.dart';
import 'library_store.dart';

/// The folder the library starts with: `~/Comics` on the laptop, the
/// Comics folder in the phone's shared storage on Android. Null when there
/// is no home to look in. The home comes from [appEnvironment], so tests
/// get their scratch one.
String? defaultComicsFolder({Map<String, String>? environment, bool? android}) {
  if (android ?? Platform.isAndroid) return '/storage/emulated/0/Comics';
  final home = (environment ?? appEnvironment)['HOME'];
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

/// Takes library folder [id] at [path] out of the library: its rows in
/// the index go, nothing on disk is touched. Taking out the default folder
/// is remembered, so the next start doesn't put it back. True when this
/// call is what made it remembered, which [restoreLibraryFolder] takes
/// back.
Future<bool> removeLibraryFolder(
  LibraryStore library,
  SettingsStore settings,
  int id,
  String path, {
  String? defaultFolder,
}) async {
  final folder = defaultFolder ?? defaultComicsFolder();
  var remembered = false;
  if (folder != null && p.equals(p.normalize(p.absolute(folder)), path)) {
    remembered = !(await settings.loadBool(SettingsStore.defaultFolderRemoved) ?? false);
    await settings.saveBool(SettingsStore.defaultFolderRemoved, true);
  }
  await library.removeRoot(id);
  return remembered;
}

/// Puts the library folder [path] back after [removeLibraryFolder] (the
/// notice's Undo); [forget] is what that call answered, so the default
/// folder is the default again and not one that was taken out. The caller
/// scans: the folder's comics are found as on any first scan.
Future<void> restoreLibraryFolder(
  LibraryStore library,
  SettingsStore settings,
  String path, {
  required bool forget,
}) async {
  await library.addRoot(path);
  if (forget) await settings.saveBool(SettingsStore.defaultFolderRemoved, false);
}
