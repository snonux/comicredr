import 'dart:convert';
import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/meta_edits.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:drift/drift.dart' show Value;
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

  Future<void> importPanels(String path, {String model = 'Opus 5.5', String? effort, int page = 1}) async {
    final json = File('${tmp.path}/panels.json')
      ..writeAsStringSync(
        jsonEncode({
          'pages': {
            '$page': {
              'panels': [
                [5, 5, 95, 45],
              ],
            },
            '${page + 1}': {'panels': <List<int>>[]},
          },
        }),
      );
    final result = await Process.run('python3', [
      'tool/llm_panels.py',
      'import',
      path,
      json.path,
      '--index',
      '${tmp.path}/no-index',
      '--harness',
      'Codex',
      '--model',
      model,
      if (effort != null) ...['--effort', effort],
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  Future<(String, String)> bookWithImport() async {
    final path = writeBook(tmp, 'Daredevil 181.cbz', 3);
    final key = await contentKey(path);
    await sync.attach(path, key, folder: false);
    await sync.write(key);
    await importPanels(path);
    await sync.attach(path, key, folder: false);
    return (path, key);
  }

  test('the record comes in from the sidecar and stays when the app writes it again', () async {
    final (path, key) = await bookWithImport();
    expect((await library().panelImportsOf(key)).single.harness, 'Codex');
    final record = (await library().panelImportsOf(key)).single;
    expect(record.model, 'Opus 5.5');
    final imported = await sync.gather(key);
    expect(imported.analysed.map((a) => a.modelName), ['Opus 5.5', 'Opus 5.5']);
    expect(imported.analysed.map((a) => a.modelEffort), everyElement(isNull));
    expect(imported.panels.single.modelName, 'Opus 5.5');
    expect(imported.panels.single.modelEffort, isNull);
    await sync.write(key);
    final side = readSidecar(sidecarPath(path, folder: false))!;
    expect(side.overrides[panelImportField], imported.overrides[panelImportField]);
    expect(side.analysed.map((a) => a.modelName), ['Opus 5.5', 'Opus 5.5']);
    expect(side.panels.single.modelName, 'Opus 5.5');
  });

  test('successive models keep page attribution, including empty pages and known effort', () async {
    final (path, key) = await bookWithImport();
    await importPanels(path, model: 'Another model', effort: 'high', page: 2);
    await sync.attach(path, key, folder: false);
    final store = PanelStore(db);
    final found = await store.load(key, source: PanelSource.classicCv, version: 1);
    expect(found[0]!.modelName, 'Opus 5.5');
    expect(found[0]!.modelEffort, isNull);
    expect(found[1]!.modelName, 'Another model');
    expect(found[1]!.modelEffort, 'high');
    expect(found[2]!.frames, isEmpty);
    expect(found[2]!.modelName, 'Another model');
    expect(found[2]!.modelEffort, 'high');
    await store.save(key, 1, found[1]!);
    await sync.write(key);
    final side = readSidecar(sidecarPath(path, folder: false))!;
    final panel = side.panels.singleWhere((p) => p.page == 1);
    expect((panel.modelName, panel.modelEffort), ('Another model', 'high'));
    final record = jsonDecode(MetaEdit.decode(side.overrides[panelImportField]!).value!) as Map<String, dynamic>;
    expect((record['runs'] as List<dynamic>).last['effort'], 'high');
  });

  test('the tool upgrades old sidecars without losing personal data', () async {
    final (path, key) = await bookWithImport();
    final sidePath = sidecarPath(path, folder: false);
    final old = sqlite3.open(sidePath);
    for (final table in ['panels', 'analysed_pages']) {
      old.execute('ALTER TABLE $table DROP COLUMN model_name');
      old.execute('ALTER TABLE $table DROP COLUMN model_effort');
    }
    old.execute('ALTER TABLE panels DROP COLUMN shape');
    old.execute('ALTER TABLE analysed_pages DROP COLUMN trim');
    old.execute('DROP TABLE collections');
    old.execute("INSERT INTO bookmarks VALUES ('keep-me', 1, NULL, NULL, 'A note', 123, NULL)");
    old.execute('UPDATE meta SET schema_version = 1');
    old.close();
    expect(readSidecar(sidePath)!.analysed.first.modelName, isNull);
    await importPanels(path, effort: 'medium');
    await sync.attach(path, key, folder: false);
    await sync.write(key);
    final side = readSidecar(sidePath)!;
    expect(side.schemaVersion, sidecarSchemaVersion);
    expect(side.bookmarks.single.note, 'A note');
    expect(side.analysed.map((a) => a.modelEffort), everyElement('medium'));
    expect(side.panels.single.modelEffort, 'medium');
  });

  test('attribution added to an existing run survives a merge in either direction', () async {
    final (path, key) = await bookWithImport();
    final attributed = readSidecar(sidecarPath(path, folder: false))!;
    final legacy = SidecarData(
      contentKey: key,
      analysed: [
        for (final a in attributed.analysed) a.copyWith(modelName: const Value(null), modelEffort: const Value(null)),
      ],
      panels: [
        for (final p in attributed.panels) p.copyWith(modelName: const Value(null), modelEffort: const Value(null)),
      ],
    );
    for (final merged in [mergeSidecars(legacy, attributed), mergeSidecars(attributed, legacy)]) {
      expect(merged.analysed.map((a) => a.modelName), everyElement('Opus 5.5'));
      expect(merged.panels.single.modelName, 'Opus 5.5');
    }
  });

  test('a schema 12 index gains nullable attribution without changing existing runs', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement(
      "INSERT INTO analysed_pages (content_key, page, source, model_ver, millis, analysed_at) "
      "VALUES ('k', 0, 'manual', 1, 0, 123)",
    );
    for (final table in ['panels', 'analysed_pages']) {
      await old.customStatement('ALTER TABLE $table DROP COLUMN model_name');
      await old.customStatement('ALTER TABLE $table DROP COLUMN model_effort');
    }
    await old.customStatement('PRAGMA user_version = 12');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    try {
      final page = (await upgraded.select(upgraded.analysedPages).get()).single;
      expect((page.source, page.modelVer, page.modelName, page.modelEffort), ('manual', 1, null, null));
    } finally {
      await upgraded.close();
    }
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
