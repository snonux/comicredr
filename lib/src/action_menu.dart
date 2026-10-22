import 'package:flutter/material.dart';
import 'package:reader_input/reader_input.dart';

import 'hotkeys.dart';
import 'reader/layout.dart';
import 'reader/reader_notifier.dart';

/// One line of the menu: what it does, as an intent, so a menu line, a key
/// and a gesture are one action; [on] ticks a setting that is on now.
class MenuEntry {
  const MenuEntry(this.intent, this.label, this.icon, {this.on = false});

  final ReaderIntent intent;
  final String label;
  final IconData icon;
  final bool on;
}

/// A titled run of [MenuEntry]s.
class MenuGroup {
  const MenuGroup(this.title, this.entries);

  final String title;
  final List<MenuEntry> entries;
}

/// The menu's lines for the app as a whole, at the end of both menus.
List<MenuEntry> appEntries({required bool fullscreen}) => [
  MenuEntry(
    ReaderIntent.fullscreen,
    fullscreen ? 'Leave fullscreen' : 'Fullscreen',
    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
    on: fullscreen,
  ),
  const MenuEntry(ReaderIntent.showTime, 'The time', Icons.schedule),
  const MenuEntry(ReaderIntent.showTouchGuide, 'Touch tutorial', Icons.touch_app_outlined),
  const MenuEntry(ReaderIntent.showKeymap, 'Keys and gestures', Icons.keyboard_outlined),
  const MenuEntry(ReaderIntent.showSettings, 'Settings', Icons.settings_outlined),
];

/// Everything there is to do with the open comic that the status line has
/// no button for, so a phone without a keyboard reaches all of it: the
/// keys' actions, by touch. The status line's own buttons are left out,
/// but for Details and the page parts, which a phone's status line has no
/// room for.
List<MenuGroup> readerMenu(ReaderState s, {required bool s3}) {
  final guided = s.guided;
  return [
    MenuGroup('This comic', [
      const MenuEntry(ReaderIntent.showDetails, 'Details', Icons.info_outline),
      const MenuEntry(ReaderIntent.toggleFavourite, 'Favourite: add or take out', Icons.star_outline),
      const MenuEntry(ReaderIntent.toggleStarted, 'Reading started: mark or take the mark off', Icons.auto_stories),
      const MenuEntry(ReaderIntent.toggleCompleted, 'Completed: mark or take the mark off', Icons.task_alt),
      const MenuEntry(ReaderIntent.addToCollection, 'Put in a collection…', Icons.collections_bookmark_outlined),
      const MenuEntry(ReaderIntent.nextBook, 'Next comic', Icons.skip_next),
      const MenuEntry(ReaderIntent.prevBook, 'Previous comic', Icons.skip_previous),
      const MenuEntry(ReaderIntent.continueReading, 'The comic read before this one', Icons.history),
      if (s3) ...const [
        MenuEntry(ReaderIntent.uploadToS3, 'Upload to S3, or sync it', Icons.cloud_upload_outlined),
        MenuEntry(ReaderIntent.removeFromS3, 'Remove from S3…', Icons.cloud_off_outlined),
      ],
      const MenuEntry(ReaderIntent.resetBook, 'Reset…', Icons.restart_alt),
      const MenuEntry(ReaderIntent.deleteBook, 'Delete…', Icons.delete_outline),
    ]),
    MenuGroup('Go to', [
      const MenuEntry(ReaderIntent.firstPage, 'First page', Icons.first_page),
      const MenuEntry(ReaderIntent.lastPage, 'Last page', Icons.last_page),
      if (s.bookmarks.isNotEmpty) ...const [
        MenuEntry(ReaderIntent.nextBookmark, 'Next bookmark', Icons.bookmark_outline),
        MenuEntry(ReaderIntent.prevBookmark, 'Previous bookmark', Icons.bookmark_outline),
      ],
      if (s.jumpedFrom != null) const MenuEntry(ReaderIntent.jumpBack, 'Back to before the jump', Icons.undo),
    ]),
    MenuGroup('View', [
      const MenuEntry(ReaderIntent.pickPart, 'Enlarge a part of the page', Icons.crop_free),
      if (guided) ...[
        MenuEntry(ReaderIntent.toggleBalloons, 'Balloon by balloon', Icons.chat_bubble_outline, on: s.balloons),
        MenuEntry(
          ReaderIntent.toggleWholePage,
          'Whole page before and after its panels',
          Icons.crop_original,
          on: s.wholePageSteps,
        ),
        MenuEntry(
          ReaderIntent.togglePauseWhole,
          'Hold on a page shown whole',
          Icons.pause_circle_outline,
          on: s.pauseWhole,
        ),
      ] else ...[
        MenuEntry(ReaderIntent.toggleSpread, 'Two pages side by side', Icons.menu_book, on: s.mode == PageMode.spread),
        if (s.mode == PageMode.spread)
          const MenuEntry(ReaderIntent.shiftSpread, 'Pair the pages the other way', Icons.compare_arrows),
        const MenuEntry(ReaderIntent.fitWidth, 'Fit width', Icons.width_wide),
        const MenuEntry(ReaderIntent.fitHeight, 'Fit height', Icons.height),
        const MenuEntry(ReaderIntent.fitPage, 'Fit the whole page', Icons.fit_screen),
      ],
      MenuEntry(ReaderIntent.toggleDirection, 'Right to left (manga)', Icons.swap_horiz, on: s.rightToLeft),
      const MenuEntry(ReaderIntent.rotateClockwise, 'Turn clockwise', Icons.rotate_right),
      const MenuEntry(ReaderIntent.rotateCounterClockwise, 'Turn counter-clockwise', Icons.rotate_left),
      if (s.rotation != 0) const MenuEntry(ReaderIntent.rotateReset, 'Turn upright', Icons.screen_rotation_alt),
    ]),
    MenuGroup('Picture', [
      MenuEntry(ReaderIntent.autoTrim, 'Trim the scan margins', Icons.crop, on: s.trim),
      MenuEntry(ReaderIntent.nightFilter, 'Night filter', Icons.nightlight_outlined, on: s.night),
      MenuEntry(ReaderIntent.cleanUp, 'Clean up old scans', Icons.auto_fix_high, on: s.cleanUp),
    ]),
    MenuGroup('App', [
      const MenuEntry(ReaderIntent.showTouchZones, 'Show the touch zones', Icons.grid_on),
      const MenuEntry(ReaderIntent.back, 'Back to the library', Icons.arrow_back),
      ...appEntries(fullscreen: s.fullscreen),
    ]),
  ];
}

/// Opens [groups] as a menu; the action picked, or null when it was left.
/// The caller runs the action once the menu has gone, so a dialog the
/// action asks with comes up on top.
Future<ReaderIntent?> showActionMenu(BuildContext context, List<MenuGroup> groups) => showDialog<ReaderIntent>(
  context: context,
  builder: (context) => ActionMenu(groups: groups),
);

/// The menu: a list of lines, at the bottom of a phone's screen where a
/// thumb reaches, in the middle of a wider one. Each line names its key,
/// so the menu teaches the keys too.
class ActionMenu extends StatelessWidget {
  const ActionMenu({super.key, required this.groups});

  final List<MenuGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    var first = true;
    Widget line(MenuEntry e) {
      final focus = first;
      first = false;
      return ListTile(
        key: Key('menu-${e.intent.name}'),
        autofocus: focus,
        dense: true,
        leading: Icon(e.icon),
        title: Text(KeyHints.tip(context, e.label, e.intent)),
        trailing: e.on ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, e.intent),
      );
    }

    return DialogHotkeys(
      child: Dialog(
        key: const Key('actionMenu'),
        alignment: narrow ? Alignment.bottomCenter : Alignment.center,
        insetPadding: narrow ? const EdgeInsets.fromLTRB(8, 24, 8, 8) : const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 440, maxHeight: size.height * (narrow ? 0.8 : 0.85)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                // Every line built, not lazily: Tab walks them all, and a
                // line scrolled away keeps its focus node.
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final g in groups)
                        if (g.entries.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                            child: Text(g.title, style: theme.textTheme.titleSmall?.copyWith(color: theme.hintColor)),
                          ),
                          for (final e in g.entries) line(e),
                        ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('menuClose'),
                    onPressed: () => Navigator.pop(context),
                    child: const Mnemonic('Close'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
