import 'dart:math';

/// Every action the reader can take. Keys, gestures and menus all dispatch
/// one of these, never a function directly (design plan section 5).
enum ReaderIntent {
  nextStep('Next panel in guided view, next page or spread otherwise; next cover in the library'),
  prevStep('Previous panel in guided view, previous page or spread otherwise; previous cover in the library'),
  nextPage('Next page, ignoring panels'),
  prevPage('Previous page, ignoring panels'),
  panDown('Pan down, or scroll in continuous mode; the cover below in the library'),
  panUp('Pan up, or scroll in continuous mode; the cover above in the library'),
  halfPageDown('Half-screen scroll down in continuous mode'),
  halfPageUp('Half-screen scroll up in continuous mode'),
  firstPage('First page; first cover in the library'),
  lastPage('Last page, or page N with a count; last cover in the library'),
  pageGrid('Page thumbnails: pick a page to jump to'),
  showDetails(
    "Details of this comic: file, pages and scan quality, metadata, reading, panels and balloons found; the selected book's in the library",
  ),
  nextBook('Next book in the series, or in the same folder'),
  prevBook('Previous book in the series, or in the same folder'),
  toggleGuided('Guided view, there and back'),
  toggleBalloons('Balloon by balloon inside each panel in guided view, on and off'),
  toggleWholePage('Whole page before and after its panels in guided view, on and off'),
  togglePauseWhole('Hold one step on a page guided view shows whole before turning, on and off'),
  cyclePauseCue('How a held page shows it: wine-red background or zoom out and back'),
  cycleModeForward('Cycle single, double, continuous, guided; next library tab'),
  cycleModeBack('Cycle modes backwards; previous library tab'),
  toggleSpread('Single page or two-page spread'),
  shiftSpread('Shift the spread pairing by one'),
  toggleContinuous('Continuous vertical scroll on or off'),
  toggleDirection('Reading direction for this book'),
  fitWidth('Fit width'),
  fitHeight('Fit height'),
  fitPage('Fit whole page; re-centre the panel in guided view'),
  zoomIn('Zoom in'),
  zoomOut('Zoom out'),
  zoomReset('Reset zoom'),
  zoomToggle('Zoom in on that spot, or back out when zoomed; re-centre the panel in guided view'),
  autoTrim('Auto-trim scan margins'),
  nightFilter('Night filter'),
  cleanUp('Clean up old scans: paper, contrast, sharpness'),
  fullscreen('Fullscreen: only the comic, no title bar, border or status line; Esc leaves it too'),
  bookmark('Bookmark this page, or this panel in guided view; again to take the bookmark off'),
  nextBookmark('Next bookmark in this book'),
  prevBookmark('Previous bookmark in this book'),
  bookmarkList('Bookmarks and marks in this book: jump, add a note, remove; the Bookmarks tab in the library'),
  remove('Remove the selected bookmark in a bookmark list'),
  setMark('Set mark a-z'),
  jumpMark('Jump to mark a-z'),
  jumpBack('Jump back to before the last jump'),
  search('Search the library; search the book text in the reader'),
  searchNext('Next match'),
  searchPrev('Previous match'),
  openFile('Open a file without adding it to the library'),
  openFolder('Open a folder of page images as a book'),
  back('Back out one level, ending at the library'),
  up('Up to the folder above in the library'),
  activate('Open the selected book, series or folder in the library'),
  addRoot('Add a folder to the library (~/Comics is in it by default, if it exists)'),
  rescan('Rescan the library folders'),
  toggleShuffle(
    "Shuffle in the library's Folders tab: each comic shows a random page instead of its cover, on and off",
  ),
  reshuffle('Pick other random pages for shuffle in the Folders tab'),
  resetBook('Reset this comic: find its panels again, or forget its bookmarks and position too'),
  editBook("Edit the selected book's title, series, issue and creators in the library; on a series, rename it"),
  showKeymap('Show the keymap'),
  showTouchZones('Show the touch zones for a moment');

  const ReaderIntent(this.description);

  final String description;
}

/// One resolved key sequence or gesture: the intent, plus the count typed
/// before it (`5l`), the register letter for marks (`ma`, `'a`), and for a
/// gesture the point on the reader it happened at, in logical pixels.
class ReaderCommand {
  const ReaderCommand(this.intent, {this.count, this.register, this.at});

  final ReaderIntent intent;
  final int? count;
  final String? register;

  /// Where a touch landed, so a double-tap zooms in on that spot rather
  /// than the middle of the screen. Keys leave it null.
  final Point<double>? at;

  /// The count to act on: a missing count means once.
  int get times => count ?? 1;

  @override
  bool operator ==(Object other) =>
      other is ReaderCommand &&
      other.intent == intent &&
      other.count == count &&
      other.register == register &&
      other.at == at;

  @override
  int get hashCode => Object.hash(intent, count, register, at);

  @override
  String toString() =>
      'ReaderCommand(${intent.name}'
      '${count != null ? ', count: $count' : ''}'
      '${register != null ? ', register: $register' : ''}'
      '${at != null ? ', at: (${at!.x}, ${at!.y})' : ''})';
}
