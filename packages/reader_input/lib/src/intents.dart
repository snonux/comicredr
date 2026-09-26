import 'dart:math';

/// Every action the reader can take. Keys, gestures and menus all dispatch
/// one of these, never a function directly (design plan section 5).
enum ReaderIntent {
  nextStep('Next panel in guided view, next page or spread otherwise; next cover in the library'),
  prevStep('Previous panel in guided view, previous page or spread otherwise; previous cover in the library'),
  nextPage('Next page, ignoring panels'),
  prevPage('Previous page, ignoring panels'),
  panDown('Pan down; the cover below in the library'),
  panUp('Pan up; the cover above in the library'),
  halfPageDown('A screen down in the page grid (continuous scroll is not built yet)'),
  halfPageUp('A screen up in the page grid (continuous scroll is not built yet)'),
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
  togglePauseWhole('Wine red on a page guided view shows whole, and a quick step held there, on and off'),
  cycleModeForward('Cycle single, double, guided; next library tab'),
  cycleModeBack('Cycle modes backwards; previous library tab'),
  toggleSpread('Single page or two-page spread'),
  shiftSpread('Shift the spread pairing by one'),
  toggleContinuous('Continuous vertical scroll (not built yet)'),
  toggleDirection('Reading direction for this book'),
  rotateClockwise(
    'Turn the comic a quarter turn clockwise, or N quarters with a count; kept for this book, in guided view too',
  ),
  rotateCounterClockwise('Turn the comic a quarter turn counter-clockwise'),
  rotateReset('Turn the comic back upright'),
  fitWidth('Fit width'),
  fitHeight('Fit height'),
  fitPage('Fit whole page; re-centre the panel in guided view'),
  zoomIn('Zoom in'),
  zoomOut('Zoom out'),
  zoomReset('Reset zoom'),
  zoomToggle('Zoom in on that spot, or back out when zoomed; re-centre the panel in guided view'),
  regionUpperHalf(
    'Upper half of the page, enlarged; l and h step to the other half, then on; again or Esc for the whole page',
  ),
  regionLowerHalf('Lower half of the page, enlarged'),
  regionUpperThird(
    'Upper third of the page, enlarged; l and h step through the thirds, then on; again or Esc for the whole page',
  ),
  regionMiddleThird('Middle third of the page, enlarged'),
  regionLowerThird('Lower third of the page, enlarged'),
  regionTopLeft(
    'Top-left quarter of the page, enlarged; l and h step through the quarters in reading order, then on; again or Esc for the whole page',
  ),
  regionTopRight('Top-right quarter of the page, enlarged'),
  regionBottomLeft('Bottom-left quarter of the page, enlarged'),
  regionBottomRight('Bottom-right quarter of the page, enlarged'),
  autoTrim('Auto-trim scan margins'),
  nightFilter('Night filter'),
  cleanUp('Clean up old scans: paper, contrast, sharpness'),
  fullscreen(
    'Fullscreen: no title bar or border; in the reader only the comic. Esc at the top of the library leaves it too',
  ),
  bookmark('Bookmark this page, or this panel in guided view; again to take the bookmark off'),
  nextBookmark('Next bookmark in this book'),
  prevBookmark('Previous bookmark in this book'),
  bookmarkList('Bookmarks and marks in this book: jump, add a note, remove; the Bookmarks tab in the library'),
  toggleFavourite('Add this comic to the Favourites collection, or take it out; the selected book in the library'),
  showFavourites('The Favourites collection in the library'),
  remove('Remove the selected bookmark in a bookmark list; take the selected comic out of the Favourites'),
  setMark('Set mark a-z'),
  jumpMark('Jump to mark a-z'),
  jumpBack('Jump back to before the last jump'),
  search('Search the library (searching inside a book is not built yet)'),
  searchNext('Next match in a book (not built yet)'),
  searchPrev('Previous match in a book (not built yet)'),
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
  deleteBook('Delete this comic and its sidecar, after asking; the selected book in the library'),
  editBook("Edit the selected book's title, series, issue and creators in the library; on a series, rename it"),
  showKeymap('Show the keymap'),
  showTouchZones('Show the touch zones for a moment'),
  showTime('The time, large, for two seconds, then it fades');

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
