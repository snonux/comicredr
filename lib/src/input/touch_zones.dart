import 'package:flutter/material.dart';
import 'package:reader_input/reader_input.dart';

/// A short name for what a gesture does, to write in its zone. Right to
/// left mirrors the step actions (as it does the arrow keys), so the label
/// says where the tap really goes.
String touchLabel(ReaderIntent intent, {bool rightToLeft = false}) {
  switch (intent) {
    case ReaderIntent.nextStep:
      return rightToLeft ? 'Back' : 'Next';
    case ReaderIntent.prevStep:
      return rightToLeft ? 'Next' : 'Back';
    case ReaderIntent.nextPage:
      return 'Next page';
    case ReaderIntent.prevPage:
      return 'Previous page';
    case ReaderIntent.fullscreen:
      return 'Status line';
    case ReaderIntent.zoomToggle:
      return 'Zoom';
    case ReaderIntent.toggleGuided:
      return 'Guided view';
    case ReaderIntent.toggleBalloons:
      return 'Balloons';
    case ReaderIntent.showKeymap:
      return 'Keys';
    case ReaderIntent.showTouchZones:
      return 'Zones';
    case ReaderIntent.showTime:
      return 'Time';
    case ReaderIntent.back:
      return 'Library';
    default:
      // The description up to its first clause, which names the action.
      final d = intent.description.split(RegExp('[,;]')).first;
      return d.length <= 22 ? d : '${d.substring(0, 21)}…';
  }
}

/// The 3x3 touch grid with what a tap, a double-tap and a long press do in
/// each zone, and below it the swipes and the two-finger tap. Shown over
/// the reader for a moment (`gt`, or after picking a preset), and small in
/// Settings.
class TouchZonesView extends StatelessWidget {
  const TouchZonesView({super.key, required this.map, this.rightToLeft = false, this.compact = false});

  final TouchMap map;
  final bool rightToLeft;

  /// Small, for the Settings preview: taps only, smaller text.
  final bool compact;

  String _label(ReaderIntent? i) => i == null ? '' : touchLabel(i, rightToLeft: rightToLeft);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = compact ? theme.textTheme.labelMedium : theme.textTheme.titleMedium;
    final small = compact ? theme.textTheme.labelSmall : theme.textTheme.bodyMedium;
    const edge = TouchZone.edge;
    Widget cell(TouchZone z) {
      final extra = [
        if (map.action(TouchGesture.doubleTap, z) case final i?) 'Double-tap: ${_label(i)}',
        if (map.action(TouchGesture.longPress, z) case final i?) 'Hold: ${_label(i)}',
      ];
      return Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: z.column == 1 ? 0.45 : 0.6),
          border: Border.all(color: Colors.white54, width: compact ? 0.5 : 1),
        ),
        padding: const EdgeInsets.all(4),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _label(map.action(TouchGesture.tap, z)),
                style: big?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              if (!compact)
                for (final e in extra) Text(e, style: small?.copyWith(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    final grid = Column(
      children: [
        for (var r = 0; r < 3; r++)
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < 3; c++)
                  Expanded(
                    flex: ((c == 1 ? 1 - 2 * edge : edge) * 100).round(),
                    child: cell(TouchZone.values[r * 3 + c]),
                  ),
              ],
            ),
          ),
      ],
    );
    if (compact) return grid;
    final others = [
      for (final g in [
        TouchGesture.swipeLeft,
        TouchGesture.swipeRight,
        TouchGesture.swipeUp,
        TouchGesture.swipeDown,
        TouchGesture.twoFingerTap,
      ])
        if (map.action(g) case final i?) '${g.label}: ${_label(i)}',
    ];
    return Stack(
      children: [
        Positioned.fill(child: grid),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  [...others, 'Pinch to zoom'].join('  ·  '),
                  textAlign: TextAlign.center,
                  style: small?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
