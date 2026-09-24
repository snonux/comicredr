import 'package:comic_analysis/comic_analysis.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Two frames filling the art of a page scanned with a 15% margin all
  // round: 49% of the page, all of the part the detector looked at.
  const trim = Trim(0.15, 0.15, 0.85, 0.85);
  final frames = [const Panel(0.15, 0.15, 0.7, 0.34), const Panel(0.15, 0.51, 0.7, 0.34)];

  test('the gate judges frames against the part of the page detection saw', () {
    expect(PagePanels(frames).gate.passed, isFalse, reason: 'on the whole page they cover too little');
    final panels = PagePanels(frames, const [], trim);
    expect(panels.gate.passed, isTrue, reason: panels.gate.reasons.join('; '));
    expect(panels.stops(rightToLeft: false), frames, reason: 'the stops stay on the whole page');
  });
}
