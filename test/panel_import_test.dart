import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/meta_edits.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/fixtures.dart';

/// Exactly what tool/llm_panels.py's `record` writes into the overrides
/// table's value column for one run (json.dumps with tight separators).
const toolRecord =
    '{"value":"{\\"runs\\":[{\\"harness\\":\\"Claude Code\\",\\"model\\":\\"claude-opus-5-5\\",\\"prompt\\":1,'
    '\\"pages\\":\\"1-3\\",\\"at\\":1791915226477}]}","at":1791915226477}';

/// The record of panels drawn by a large model (tool/llm_panels.py,
/// docs/llm-panels.md): read as the tool writes it, kept out of the
/// metadata edits, carried in from the sidecar, and dropped by Redo panels
/// with the panels while Reset everything drops it too.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late SidecarSync sync;
  LibraryStore library() => LibraryStore(db);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('panel_import_test');
    db = AppDatabase(NativeDatabase.memory());
    sync = SidecarSync(
      db,
      progress: ProgressStore(db, debounce: Duration.zero),
      debounce: Duration.zero,
      storeDir: () async => null,
    );
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('the tool\'s record reads as its runs, and is no metadata edit', () {
    final runs = PanelImportRun.decodeAll(toolRecord);
    expect(runs, hasLength(1));
    expect(runs.single.harness, 'Claude Code');
    expect(runs.single.model, 'claude-opus-5-5');
    expect(runs.single.prompt, 1);
    expect(runs.single.pages, '1-3');
    expect(runs.single.at, DateTime.fromMillisecondsSinceEpoch(1791915226477));
    expect(activeEdits({panelImportField: toolRecord}), isEmpty);
    expect(PanelImportRun.decodeAll(null), isEmpty);
    expect(PanelImportRun.decodeAll('not json'), isEmpty);
    expect(PanelImportRun.decodeAll(MetaEdit.undo(at: DateTime(2026)).encode()), isEmpty);
  });

  test('imported panels may overlap, a detector\'s may not', () {
    // The top panel grown to take in a balloon hanging over the one below it, beside an inset.
    const frames = [Panel(0.05, 0.05, 0.9, 0.5), Panel(0.05, 0.4, 0.9, 0.55), Panel(0.6, 0.45, 0.3, 0.2)];
    expect(PagePanels(frames).gate.passed, isFalse);
    expect(PagePanels(frames, const [], Trim.full, true).gate.passed, isTrue);
    expect(PagePanels(frames, const [], Trim.full, true).stops(rightToLeft: false), frames);
  });

  Future<(String, String)> bookWithImport() async {
    final path = writeBook(tmp, 'Daredevil 181.cbz', 3);
    final key = await contentKey(path);
    await sync.attach(path, key, folder: false);
    await sync.write(key);
    // What the tool adds to the sidecar the app wrote: a manual page and the record.
    final side = sqlite3.open(sidecarPath(path, folder: false));
    side.execute("INSERT INTO analysed_pages VALUES (0, 'manual', 1, 0, 1791915226477, NULL)");
    side.execute("INSERT INTO panels VALUES (0, 0, 0.05, 0.05, 0.9, 0.4, 'frame', 'manual', 1, 1.0, NULL)");
    side.execute('INSERT OR REPLACE INTO overrides VALUES (?, ?)', [panelImportField, toolRecord]);
    side.close();
    await sync.attach(path, key, folder: false);
    return (path, key);
  }

  test('the record comes in from the sidecar and stays when the app writes it again', () async {
    final (path, key) = await bookWithImport();
    expect((await library().panelImportsOf(key)).single.harness, 'Claude Code');
    await sync.write(key);
    expect(readSidecar(sidecarPath(path, folder: false))!.overrides[panelImportField], toolRecord);
  });

  test('Redo panels drops the record with the imported panels; it does not come back', () async {
    final (path, key) = await bookWithImport();
    expect(await sync.reset(key, everything: false), isTrue);
    expect(await library().panelImportsOf(key), isEmpty);
    final side = readSidecar(sidecarPath(path, folder: false))!;
    expect(side.overrides, isNot(contains(panelImportField)));
    expect(side.analysed.where((a) => a.source == 'manual'), isEmpty);
    await sync.attach(path, key, folder: false);
    expect(await library().panelImportsOf(key), isEmpty);
  });

  test('Reset everything drops it too', () async {
    final (path, key) = await bookWithImport();
    expect(await sync.reset(key, everything: true), isTrue);
    expect(await library().panelImportsOf(key), isEmpty);
    expect(readSidecar(sidecarPath(path, folder: false))?.overrides ?? const {}, isNot(contains(panelImportField)));
  });
}
