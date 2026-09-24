// Runs refineOutlines on pages dumped as raw RGBA plus a JSON of normalised
// frames and balloons (spike/outlines.py --dump), and prints the outlines
// as JSON, so the Dart port can be checked against the Python prototype.
//
//   dart run tool/outlines.dart DUMP_DIR > dart.json
import 'dart:convert';
import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';

void main(List<String> args) {
  final dir = Directory(args.single);
  final out = <String, Object?>{};
  final sw = Stopwatch();
  var pages = 0;
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.rgba'))) {
    final name = f.uri.pathSegments.last.replaceAll('.rgba', '');
    final meta = jsonDecode(File(f.path.replaceAll('.rgba', '.json')).readAsStringSync()) as Map<String, dynamic>;
    List<Panel> panels(String key, PanelKind kind) => [
      for (final b in (meta[key] as List).cast<List>())
        Panel(
          (b[0] as num).toDouble(),
          (b[1] as num).toDouble(),
          (b[2] as num).toDouble(),
          (b[3] as num).toDouble(),
          kind: kind,
        ),
    ];
    sw.start();
    final got = refineOutlines(
      f.readAsBytesSync(),
      meta['w'] as int,
      meta['h'] as int,
      panels('frames', PanelKind.frame),
      panels('balloons', PanelKind.balloon),
    );
    sw.stop();
    pages++;
    out[name] = [for (final p in got) p.shape];
  }
  stderr.writeln('$pages pages, ${(sw.elapsedMilliseconds / pages).toStringAsFixed(1)} ms a page');
  stdout.write(jsonEncode(out));
}
