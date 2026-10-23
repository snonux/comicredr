import 'package:flutter/material.dart';
import 'package:reader_input/reader_input.dart';

import 'hotkeys.dart';
import 'input/touch_zones.dart';

/// Opens the touch tutorial: every gesture on a page of its own, with a
/// picture and a few plain words, read from [map] (the preset picked in
/// Settings with keys.toml's `[touch]` lines over it), so a left-handed
/// reader is shown the left-handed taps. [android] says the system's back
/// gesture alongside the status line's back arrow.
Future<void> showTouchGuide(BuildContext context, {required TouchMap map, required bool android}) => showDialog<void>(
  context: context,
  builder: (_) => TouchGuide(map: map, android: android),
);

/// Where [g] does [i] on the 3x3 grid, in words: "the right edge", "the
/// middle", "anywhere"; null when it does it nowhere.
String? zonesOf(TouchMap map, TouchGesture g, ReaderIntent i) {
  final zones = [
    for (final z in TouchZone.values)
      if (map.action(g, z) == i) z,
  ];
  if (zones.isEmpty) return null;
  if (zones.length == 9) return 'anywhere';
  for (final (column, name) in const [(0, 'the left edge'), (1, 'the middle'), (2, 'the right edge')]) {
    if (zones.every((z) => z.column == column)) return name;
  }
  const names = {
    TouchZone.topLeft: 'top left',
    TouchZone.top: 'top',
    TouchZone.topRight: 'top right',
    TouchZone.left: 'left',
    TouchZone.middle: 'middle',
    TouchZone.right: 'right',
    TouchZone.bottomLeft: 'bottom left',
    TouchZone.bottom: 'bottom',
    TouchZone.bottomRight: 'bottom right',
  };
  return 'the ${zones.map((z) => names[z]).join(', ')}';
}

/// What a page of the tutorial shows: a moving finger of this kind.
enum GuideMotion { none, tap, doubleTap, hold, swipeLeft, swipeRight, swipeUp, drag, pinch, twoFingerTap }

/// One page of the tutorial.
class GuideStep {
  const GuideStep(this.title, this.text, {this.motion = GuideMotion.none, this.zones = false, this.icons = const []});

  final String title;
  final String text;
  final GuideMotion motion;

  /// The tap zones are drawn on the page in the picture.
  final bool zones;

  /// Buttons to show with their names, for the pages about buttons.
  final List<(IconData, String)> icons;
}

/// The tutorial's pages for [map]: what each gesture does, from the map,
/// and where the buttons and the menu are.
List<GuideStep> guideSteps(TouchMap map, {required bool android}) {
  String label(ReaderIntent i) => touchLabel(i).toLowerCase();
  final taps = [
    for (final i in {...map.actions(TouchGesture.tap).nonNulls})
      'Tap ${zonesOf(map, TouchGesture.tap, i)}: ${label(i)}.',
  ];
  final swipes = [
    for (final g in const [
      TouchGesture.swipeLeft,
      TouchGesture.swipeRight,
      TouchGesture.swipeUp,
      TouchGesture.swipeDown,
    ])
      if (map.action(g) case final i?) '${g.label}: ${label(i)}.',
  ];
  final zoom = zonesOf(map, TouchGesture.doubleTap, ReaderIntent.zoomToggle);
  final doubleTaps = [
    for (final i in {...map.actions(TouchGesture.doubleTap).nonNulls})
      if (i != ReaderIntent.zoomToggle)
        i == ReaderIntent.fullscreen
            ? 'Double-tap ${zonesOf(map, TouchGesture.doubleTap, i)} to turn fullscreen on or off.'
            : 'Double-tap ${zonesOf(map, TouchGesture.doubleTap, i)}: ${label(i)}.',
  ];
  final fit = [
    for (final g in const [TouchGesture.swipeDown, TouchGesture.swipeUp])
      if (map.action(g) == ReaderIntent.toggleFitWidth) g.label,
  ].firstOrNull;
  final holds = [
    for (final i in {...map.actions(TouchGesture.longPress).nonNulls})
      'Hold a finger on ${zonesOf(map, TouchGesture.longPress, i)}: ${label(i)}.',
  ];
  final menuSwipe = [
    for (final g in const [
      TouchGesture.swipeUp,
      TouchGesture.swipeDown,
      TouchGesture.swipeLeft,
      TouchGesture.swipeRight,
    ])
      if (map.action(g) == ReaderIntent.openMenu) g.label,
  ].firstOrNull;
  final twoFingers = map.action(TouchGesture.twoFingerTap);
  final back =
      'The arrow at the start of the status line leaves guided view and the comic.'
      '${android ? " Android's back gesture also leaves a picker, guided view and the comic, and goes up a folder in the library." : ""}';
  final menuIcon = android ? Icons.menu : Icons.more_vert;
  final menuName = android ? 'the hamburger menu (☰)' : '⋮';
  return [
    const GuideStep(
      'Reading by touch',
      'Everything in ComicRedr works without a keyboard. This tutorial shows the tap zones, every gesture '
          'and where the buttons are. '
          'Swipe to the next page, or tap Next.',
      motion: GuideMotion.swipeLeft,
    ),
    GuideStep(
      'Tap to turn',
      '${taps.join(' ')} The picture shows every zone. Settings → Touch has layouts for the left hand and one thumb.',
      motion: GuideMotion.tap,
      zones: true,
    ),
    if (swipes.isNotEmpty) GuideStep('Swipe', swipes.join(' '), motion: GuideMotion.swipeLeft),
    if (doubleTaps.isNotEmpty) GuideStep('Double-tap', doubleTaps.join(' '), motion: GuideMotion.doubleTap),
    GuideStep(
      'Zoom and move',
      [
        'Pinch with two fingers to zoom in and out.',
        if (zoom != null) 'Double-tap $zoom to zoom in on that spot, and again to zoom out.',
        'On a zoomed page one finger moves it around.',
        if (fit != null)
          '$fit on the page fits it to the width, where one finger scrolls up and down only; $fit at its top '
              'for the whole page again.',
      ].join(' '),
      motion: GuideMotion.pinch,
    ),
    const GuideStep(
      'Guided view, panel by panel',
      'The guided view button on the status line moves from panel to panel. The taps and a quick flick go to the '
          'next panel; a slow drag with one finger looks around, and the next step frames the panel again. '
          'In guided view the balloon button goes balloon by balloon.',
      motion: GuideMotion.drag,
      icons: [(Icons.view_quilt_outlined, 'Guided view'), (Icons.chat_bubble_outline, 'Balloon by balloon')],
    ),
    if (twoFingers != null)
      GuideStep(
        'Two fingers',
        twoFingers == ReaderIntent.pickPart
            ? 'Tap with two fingers to pick a half, a third, a strip or a quarter of the page to enlarge. '
                  'The taps then step through the parts, page by page.'
            : 'Tap with two fingers: ${label(twoFingers)}.',
        motion: GuideMotion.twoFingerTap,
      ),
    if (holds.isNotEmpty) GuideStep('Hold', holds.join(' '), motion: GuideMotion.hold),
    GuideStep(
      'The status line',
      'A tap in the middle of the page shows or hides the line along the bottom, with its buttons:',
      icons: android
          ? [
              (Icons.arrow_back, 'Back: leave guided view, then the comic'),
              (Icons.chat_bubble_outline, 'Balloon by balloon: enters guided view too'),
              (Icons.view_quilt_outlined, 'Guided view'),
              (Icons.menu, 'The menu: pages, bookmarks, fit and the other options'),
            ]
          : [
              (Icons.width_wide, 'Fit width, or the whole page'),
              (Icons.grid_view, 'All pages: tap one to go there'),
              (Icons.bookmark_add_outlined, 'Bookmark this page, or take it off'),
              (Icons.bookmarks_outlined, 'Your bookmarks in this comic'),
              (Icons.more_vert, 'The menu'),
            ],
    ),
    GuideStep(
      'The menu',
      '${menuSwipe != null ? '$menuSwipe on the page, or tap $menuName, for the menu. ' : 'Tap $menuName for the menu. '}'
          '${android ? 'It has the page grid, bookmark here or remove it, your bookmarks, fit width and the whole page. ' : ''}'
          'It has everything else: favourites, completed, collections, the next comic, the first and last page, '
          'two pages, right to left, turning the page, trimming, the night filter, reset, delete and Settings.',
      motion: GuideMotion.swipeUp,
    ),
    GuideStep(
      'The library',
      'Tap a cover to read. Hold a cover for its details: favourite, completed, collection, edit, move, delete. '
          'Pinch the covers to make them bigger or smaller. The list button marks several comics for one action, '
          'and ⋮ has the rest. $back',
      motion: GuideMotion.hold,
    ),
    GuideStep(
      'That is all',
      'Pick Touch zones and gestures in the menu ($menuName in the reader, ⋮ in the library) or in Settings → Touch '
          'whenever you want this tutorial again.',
      icons: [(menuIcon, 'The menu'), (Icons.settings_outlined, 'Settings')],
    ),
  ];
}

/// The tutorial: a page per gesture, Back and Next, dots for where one is.
class TouchGuide extends StatefulWidget {
  const TouchGuide({super.key, required this.map, required this.android});

  final TouchMap map;
  final bool android;

  @override
  State<TouchGuide> createState() => _TouchGuideState();
}

class _TouchGuideState extends State<TouchGuide> {
  final _pages = PageController();
  late final _steps = guideSteps(widget.map, android: widget.android);
  int _at = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int to) {
    if (to < 0) return;
    if (to >= _steps.length) {
      Navigator.pop(context);
      return;
    }
    final still = MediaQuery.of(context).disableAnimations;
    if (still) {
      _pages.jumpToPage(to);
    } else {
      _pages.animateToPage(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final last = _at == _steps.length - 1;
    return DialogHotkeys(
      child: Dialog(
        key: const Key('touchGuide'),
        insetPadding: EdgeInsets.all(size.width < 600 ? 12 : 40),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480, maxHeight: size.height * 0.9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SizedBox(
                  height: 560,
                  child: PageView(
                    key: const Key('touchGuidePages'),
                    controller: _pages,
                    onPageChanged: (i) => setState(() => _at = i),
                    children: [for (final s in _steps) _StepView(step: s, map: widget.map)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '${_at + 1} / ${_steps.length}',
                  key: const Key('touchGuideAt'),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Row(
                  children: [
                    TextButton(
                      key: const Key('touchGuideClose'),
                      onPressed: () => Navigator.pop(context),
                      child: const Mnemonic('Close'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const Key('touchGuideBack'),
                      onPressed: _at == 0 ? null : () => _go(_at - 1),
                      child: const Mnemonic('Back'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('touchGuideNext'),
                      autofocus: true,
                      onPressed: () => _go(_at + 1),
                      child: Mnemonic(last ? 'Done' : 'Next'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One page: the picture, the title and the words.
class _StepView extends StatelessWidget {
  const _StepView({required this.step, required this.map});

  final GuideStep step;
  final TouchMap map;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (step.zones || step.motion != GuideMotion.none)
            Center(
              child: SizedBox(
                height: 220,
                child: _PhonePicture(motion: step.motion, zones: step.zones ? map : null),
              ),
            ),
          const SizedBox(height: 16),
          Text(step.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(step.text, style: theme.textTheme.bodyLarge),
          for (final (icon, name) in step.icons)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Icon(icon, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(name, style: theme.textTheme.bodyLarge)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A phone drawn with a page on it and a finger doing the gesture. The
/// finger moves a few times when the page shows, and again on a tap on the
/// picture; still with reduced motion.
class _PhonePicture extends StatefulWidget {
  const _PhonePicture({required this.motion, this.zones});

  final GuideMotion motion;
  final TouchMap? zones;

  @override
  State<_PhonePicture> createState() => _PhonePictureState();
}

class _PhonePictureState extends State<_PhonePicture> with SingleTickerProviderStateMixin {
  late final _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.of(context).disableAnimations && !_run.isAnimating) _play();
  }

  /// Three times over, then still: a tutorial left open does not keep
  /// drawing frames.
  void _play() => _run.repeat(count: 3);

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.primary;
    return GestureDetector(
      onTap: () {
        if (!MediaQuery.of(context).disableAnimations) _play();
      },
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outline, width: 3),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.zones case final map?) TouchZonesView(map: map, compact: true) else _page(theme),
                  AnimatedBuilder(
                    animation: _run,
                    builder: (context, _) => CustomPaint(painter: _FingerPainter(widget.motion, _t, ink)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Where the run is, 0 to 1; the end pose when it is not running.
  double get _t => _run.isAnimating ? _run.value : 0.6;

  /// A comic page: four panels.
  Widget _page(ThemeData theme) {
    final panel = theme.colorScheme.surfaceContainerHighest;
    Widget box(int flex) => Expanded(
      flex: flex,
      child: Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
      ),
    );
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Expanded(child: Row(children: [box(2), box(1)])),
          Expanded(child: Row(children: [box(1)])),
          Expanded(child: Row(children: [box(1), box(2)])),
        ],
      ),
    );
  }
}

/// Draws the fingertips of [motion] at [t] (0 to 1 of one run).
class _FingerPainter extends CustomPainter {
  _FingerPainter(this.motion, this.t, this.ink);

  final GuideMotion motion;
  final double t;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (motion == GuideMotion.none) return;
    final c = size.center(Offset.zero);
    final w = size.width;
    final fill = Paint()..color = ink.withValues(alpha: 0.75);
    final ring = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    void tip(Offset at, {double grow = 0}) {
      canvas.drawCircle(at, 14, fill);
      if (grow > 0) canvas.drawCircle(at, 14 + 20 * grow, ring..color = ink.withValues(alpha: 1 - grow));
    }

    // Eased there and back within a run.
    final e = Curves.easeInOut.transform(t < 0.8 ? t / 0.8 : 1);
    switch (motion) {
      case GuideMotion.tap:
        tip(Offset(w * 0.85, c.dy), grow: t);
      case GuideMotion.doubleTap:
        tip(c, grow: (t * 2) % 1);
      case GuideMotion.hold:
        tip(c, grow: e);
      case GuideMotion.swipeLeft:
        tip(Offset(w * (0.8 - 0.6 * e), c.dy));
      case GuideMotion.swipeRight:
        tip(Offset(w * (0.2 + 0.6 * e), c.dy));
      case GuideMotion.swipeUp:
        tip(Offset(c.dx, size.height * (0.8 - 0.5 * e)));
      case GuideMotion.drag:
        tip(Offset(w * (0.5 + 0.2 * e), size.height * (0.55 - 0.15 * e)));
      case GuideMotion.pinch:
        final d = w * (0.12 + 0.18 * e);
        tip(c.translate(-d, d));
        tip(c.translate(d, -d));
      case GuideMotion.twoFingerTap:
        tip(c.translate(-w * 0.12, 0), grow: t);
        tip(c.translate(w * 0.12, 0), grow: t);
      case GuideMotion.none:
    }
  }

  @override
  bool shouldRepaint(_FingerPainter old) => old.t != t || old.motion != motion || old.ink != ink;
}
