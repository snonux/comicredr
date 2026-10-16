import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import '../hotkeys.dart';
import 'guided.dart';
import 'layout.dart';
import 'reader_notifier.dart';
import 'region.dart';

/// The line under the page: where the reader is, what it is doing, and
/// buttons for the modes a phone can't reach by key.
class StatusLine extends StatelessWidget {
  const StatusLine({
    super.key,
    required this.state,
    required this.pending,
    required this.onCommand,
    this.gridOpen = false,
    this.bookmarksOpen = false,
    this.partsOpen = false,
    this.fitWidth = false,
    this.s3Progress,
  });

  /// Whether the status line has a back button: everywhere but Android,
  /// whose back gesture does the same.
  static bool get showBack => !Platform.isAndroid;

  /// Whether the page on screen has imported panels (drawn by a large
  /// model, tool/llm_panels.py) rather than the detector's. The status line
  /// then takes the theme's tertiary colour, guided view on or off, so a
  /// reader sees at a glance which pages were drawn (snonux, 2026-10-16).
  static bool drawnPage(ReaderState s) => s.book != null && (s.panels[s.page]?.imported ?? false);

  /// Where guided view is on the page, or why it shows the whole page. A
  /// page whose panels were imported says "guided (drawn)", so the colour
  /// is not the only sign of them.
  static String _guided(ReaderState s) {
    final found = s.panels[s.page];
    if (found == null) return 'guided: finding panels…';
    final guided = found.imported ? 'guided (drawn)' : 'guided';
    final stops = s.stopsOn(s.page);
    if (stops.isEmpty) return '$guided: whole page (${found.gate.reasons.first})';
    if (s.panelIndex < 0) {
      return s.panel >= pageEnd
          ? '$guided: whole page, ${stops.length} panels read'
          : '$guided: whole page, then ${stops.length} panels';
    }
    final panel = '$guided: panel ${s.panelIndex + 1} / ${stops.length}';
    if (!s.balloons) return panel;
    final n = s.balloonsOn(s.page, s.panelIndex).length;
    if (found.balloons.isEmpty) return '$panel  ·  no balloons found';
    return n == 0
        ? '$panel  ·  no balloons'
        : '$panel  ·  balloon ${s.balloonIndex < 0 ? '–' : s.balloonIndex + 1} / $n';
  }

  final ReaderState state;
  final String pending;

  /// Whether the page grid is open.
  final bool gridOpen;

  /// Whether the bookmark list is open.
  final bool bookmarksOpen;

  /// Whether the page is fitted to the width of the screen (`zw`).
  final bool fitWidth;

  /// Whether the page parts picker is open.
  final bool partsOpen;

  /// How far the open comic's upload to S3 is, 0 to 1; null when none runs.
  final double? s3Progress;

  /// For the buttons: a phone without a keyboard has no other way into
  /// guided view, balloons or bookmarks.
  final ValueChanged<ReaderCommand> onCommand;

  /// A button for [intent]; its tooltip is [tip] and the key the keymap
  /// gives the intent now, read from the KeyHints above [context]. The
  /// key is on the button itself, which is the Row's own child: the Row
  /// matches its children by key, so a button keeps its element (ink,
  /// hover, an open tooltip) when another appears before it, as the
  /// balloons button does when guided view goes on.
  Widget _button(BuildContext context, String key, IconData icon, String tip, ReaderIntent intent, {bool on = false}) =>
      IconButton(
        key: Key(key),
        icon: Icon(icon),
        tooltip: KeyHints.tip(context, tip, intent),
        isSelected: on,
        // Full 48 px targets: the Fedora laptop has a touchscreen too.
        onPressed: () => onCommand(ReaderCommand(intent)),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = state.book;
    final drawn = drawnPage(state);
    final unit = state.unit;
    final pages = unit.isEmpty
        ? ''
        : unit.length == 1
        ? 'page ${unit.first + 1} / ${state.pageCount}'
        : 'pages ${unit.first + 1}–${unit.last + 1} / ${state.pageCount}';
    final details = [
      if (book != null) pages,
      if (book != null && state.guided) _guided(state),
      // Outside guided view the words go with the colour too.
      if (drawn && !state.guided) 'drawn panels',
      if (book != null && !state.guided && state.mode == PageMode.spread) 'spread',
      if (book != null && state.region != null) describeRegion(state.region!, rightToLeft: state.rightToLeft),
      if (state.rightToLeft) 'RTL',
      if (book != null && s3Progress != null) 'S3 ↑ ${(s3Progress! * 100).floor()}%',
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone in portrait has room for about 40 characters: the page and
        // panel counters come first there, the title after them, and the
        // file name, which repeats the title, is left out.
        final narrow = constraints.maxWidth < 600;
        // A small tablet, or a big one in split screen, has the buttons in
        // one row but was left too little room for the counters behind the
        // title and the file name: they come first there too, and the file
        // name only shows where there is room to spare.
        final countersFirst = constraints.maxWidth < 840;
        final fileName = constraints.maxWidth >= 1000;
        // The buttons read their keys from the KeyHints above this context.
        Widget button(String key, IconData icon, String tip, ReaderIntent intent, {bool on = false}) =>
            _button(context, key, icon, tip, intent, on: on);
        final left =
            (countersFirst ? [...details, if (book != null) book.title] : [if (book != null) book.title, ...details])
                .join('  ·  ');
        final status = Expanded(
          // A live region, so a screen reader reads out each notice and page
          // turn as it happens.
          child: Semantics(
            liveRegion: true,
            child: Text(
              state.message ?? left,
              key: const Key('status'),
              maxLines: narrow ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        final pendingKeys = Text(
          pending,
          key: const Key('pending'),
          style: const TextStyle(fontFamily: 'monospace'),
        );
        // Esc in a button: Android has its back gesture for this, but a
        // Linux touchscreen had no way out of guided view or the book.
        final back = book != null && showBack
            ? button('backButton', Icons.arrow_back, 'Back', ReaderIntent.back)
            : null;
        final buttons = [
          if (book != null) ...[
            const SizedBox(width: 4),
            if (state.guided)
              button(
                'balloonsButton',
                state.balloons ? Icons.chat_bubble : Icons.chat_bubble_outline,
                'Balloon by balloon',
                ReaderIntent.toggleBalloons,
                on: state.balloons,
              ),
            button(
              'guidedButton',
              state.guided ? Icons.view_quilt : Icons.view_quilt_outlined,
              'Guided view',
              ReaderIntent.toggleGuided,
              on: state.guided,
            ),
            // A tablet on its side has room for two pages, and without a
            // keyboard no other way to them. A phone has room for neither.
            if (!narrow && !state.guided)
              button(
                'spreadButton',
                state.mode == PageMode.spread ? Icons.menu_book : Icons.menu_book_outlined,
                state.mode == PageMode.spread ? 'One page' : 'Two pages side by side',
                ReaderIntent.toggleSpread,
                on: state.mode == PageMode.spread,
              ),
            // A phone has no keyboard for zw and zz; guided view frames
            // panels and has no fit. A window as narrow as a phone has the
            // back arrow too and no room left for it, but has the keys.
            if (!state.guided && !(narrow && back != null))
              fitWidth
                  ? button('fitButton', Icons.fit_screen, 'Fit the whole page', ReaderIntent.fitPage, on: true)
                  : button('fitButton', Icons.width_wide, 'Fit width', ReaderIntent.fitWidth),
            button('pagesButton', Icons.grid_view, 'Pages', ReaderIntent.pageGrid, on: gridOpen),
            // A phone has a two-finger tap for it and no room here.
            if (!narrow)
              button(
                'partsButton',
                Icons.crop_free,
                'Enlarge a part of the page',
                ReaderIntent.pickPart,
                on: partsOpen || state.parts != null,
              ),
            // A phone has no room for it here; the page grid has one.
            if (!narrow) button('detailsButton', Icons.info_outline, 'Details', ReaderIntent.showDetails),
            if (state.bookmarksHere.isNotEmpty)
              button('bookmarkButton', Icons.bookmark, 'Remove the bookmark here', ReaderIntent.bookmark, on: true)
            else
              button('bookmarkButton', Icons.bookmark_add_outlined, 'Bookmark here', ReaderIntent.bookmark),
            button(
              'bookmarksButton',
              Icons.bookmarks_outlined,
              'Bookmarks',
              ReaderIntent.bookmarkList,
              on: bookmarksOpen,
            ),
            // A phone taps the middle of the page for it, and has it in the
            // menu: the room went to the menu.
            if (!narrow)
              button(
                'fullscreenButton',
                state.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                state.fullscreen ? 'Leave fullscreen' : 'Fullscreen',
                ReaderIntent.fullscreen,
              ),
            // Everything else there is to do, so no action needs a key.
            button('menuButton', Icons.more_vert, 'Menu', ReaderIntent.openMenu),
          ],
        ];
        final colours = theme.colorScheme;
        // On a phone the buttons left the text a dozen characters, so a
        // notice or why guided view shows the page whole could not be
        // read: there the text has a line of its own above the buttons.
        final line = narrow && book != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [status, pendingKeys]),
                  Row(children: [?back, const Spacer(), ...buttons]),
                ],
              )
            : Row(
                children: [
                  if (back != null) ...[back, const SizedBox(width: 4)],
                  status,
                  pendingKeys,
                  if (book != null && fileName) ...[
                    const SizedBox(width: 12),
                    Text(
                      p.basename(book.path),
                      style: theme.textTheme.bodySmall?.copyWith(color: drawn ? colours.onTertiaryContainer : null),
                    ),
                  ],
                  ...buttons,
                ],
              );
        return Container(
          key: const Key('statusLine'),
          color: drawn ? colours.tertiaryContainer : colours.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          // A page with drawn panels has the line in the tertiary colour,
          // its text and icons in the colour made to go on it; every other
          // page keeps the usual surface.
          child: drawn
              ? DefaultTextStyle.merge(
                  style: TextStyle(color: colours.onTertiaryContainer),
                  child: IconTheme.merge(
                    data: IconThemeData(color: colours.onTertiaryContainer),
                    child: line,
                  ),
                )
              : line,
        );
      },
    );
  }
}
