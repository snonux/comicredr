import 'package:comic_analysis/comic_analysis.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('balloon stops skip captions, which only imported panels have', () {
    const frames = [Panel(0.02, 0.02, 0.96, 0.46), Panel(0.02, 0.52, 0.96, 0.46)];
    const speech = Panel(0.5, 0.1, 0.2, 0.1, kind: PanelKind.balloon);
    const caption = Panel(0.05, 0.04, 0.3, 0.06, kind: PanelKind.caption);
    const later = Panel(0.1, 0.6, 0.2, 0.1, kind: PanelKind.balloon);
    final panels = PagePanels(frames, const [caption, speech, later]);
    expect(panels.gate.passed, isTrue, reason: panels.gate.reasons.join('; '));
    expect(panels.balloonsIn(0, rightToLeft: false), [speech]);
    expect(panels.balloonsIn(1, rightToLeft: false), [later]);
    // Still kept with the page, for the details view's counts.
    expect(panels.balloons, contains(caption));
  });
}
