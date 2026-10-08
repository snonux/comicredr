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
  scrollRight('Moves a zoomed page right (smoothly), else the next step, as l'),
  scrollFaster('Smooth scrolling faster: longer steps, a held key quicker; kept'),
  scrollSlower('Smooth scrolling slower: shorter steps, a held key slower; kept'),
  scrollSmoother('Smooth scrolling smoother: softer start and stop; kept'),
  scrollCrisper('Smooth scrolling crisper: quicker start and stop; kept'),
  scrollLeft('Moves a zoomed page left (smoothly), else the previous step, as h'),
  halfPageDown('A screen down in the page grid (continuous scroll is not built yet)'),
  halfPageUp('A screen up in the page grid (continuous scroll is not built yet)'),
  firstPage('First page; first cover in the library'),
  lastPage('Last page, or page N with a number after it (G12); last cover in the library'),
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
  zoomIn('Zoom in; bigger pages in the page grid, bigger covers in the library, bigger text in the ? help'),
  zoomOut('Zoom out; smaller pages in the page grid, smaller covers in the library, smaller text in the ? help'),
  zoomReset('Reset zoom; the usual size in the page grid, the library and the ? help'),
  zoomToggle('Zoom in on that spot, or back out when zoomed; re-centre the panel in guided view'),
  regionWhole('Whole page: leave the enlarged part, still stepping through the split; Esc or 00 leave the split too'),
  regionPrevious('Leave parts of the page and go back to the usual steps (guided view or plain paging)'),
  regionUpperHalf(
    'Upper half of the page, enlarged; → and ← then go half by half, each page whole before and after; again or Esc to stop',
  ),
  regionLowerHalf('Lower half of the page, enlarged'),
  regionUpperThird(
    'Upper third of the page, enlarged; → and ← then go third by third, each page whole before and after; again or Esc to stop',
  ),
  regionMiddleThird('Middle third of the page, enlarged'),
  regionLowerThird('Lower third of the page, enlarged'),
  regionStrip1(
    'Top strip of four across the page, enlarged; → and ← then go strip by strip, each page whole before and after; again or Esc to stop',
  ),
  regionStrip2('Second strip of four from the top, enlarged'),
  regionStrip3('Third strip of four from the top, enlarged'),
  regionStrip4('Bottom strip of four, enlarged'),
  regionTopLeft(
    'Top-left quarter of the page, enlarged; → and ← then go quarter by quarter, each page whole before and after; again or Esc to stop',
  ),
  regionTopRight('Top-right quarter of the page, enlarged'),
  regionBottomLeft('Bottom-left quarter of the page, enlarged'),
  regionBottomRight('Bottom-right quarter of the page, enlarged'),
  pickPart('Page parts: pick a half, third, strip or quarter of the page to enlarge; a two-finger tap opens it too'),
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
  toggleFavourite(
    'Add this comic to the Favourites collection, or take it out; the selected book in the library, or every marked one',
  ),
  showFavourites('The Favourites collection in the library'),
  remove('Remove the selected bookmark in a bookmark list; take the selected comic out of the Favourites'),
  setMark('Set mark a-z'),
  jumpMark('Jump to mark a-z'),
  jumpBack('Jump back to before the last jump'),
  search('Search the library (searching inside a book is not built yet)'),
  searchNext('Next match in a book (not built yet)'),
  searchPrev('Previous match in a book (not built yet)'),
  openFile('Open a file without adding it to the library'),
  continueReading(
    'Continue the comic read last, where it was left, even after a restart; in a comic, the one read before it',
  ),
  openFolder('Open a folder of page images as a book'),
  back('Back out one level, ending at the library'),
  up('Up to the folder above in the library'),
  activate('Open the selected book, series or folder in the library'),
  addRoot('Add a folder to the library (~/Comics is in it by default, if it exists)'),
  removeRoot('Library: take the selected library folder out of the library; its comics stay on disk'),
  rescan('Rescan the library folders'),
  showScanFailures('Library: the comics the last scan could not read, and why'),
  toggleShuffle(
    "Shuffle in the library's tabs of covers: each comic, series and folder shows a random page instead of its cover, on and off",
  ),
  reshuffle('Pick other random pages for shuffle in the library'),
  filterFolders("Filter the library's Folders tab by type, size and modification date"),
  resetBook(
    'Reset this comic: find its panels again, or forget its bookmarks and position too; in the library every marked one',
  ),
  deleteBook('Delete this comic and its sidecar, after asking; the selected book in the library, or every marked one'),
  uploadToS3(
    'Upload this comic to your S3 bucket, or sync its sidecar if it is there; in the library the selected book, or every marked one',
  ),
  removeFromS3('Take this comic off S3, after asking; the copy on this device stays; in the library every marked one'),
  downloadFromS3(
    'Library: download the selected comic that is only on S3 to this device, or every marked one that is only there',
  ),
  moveBooks(
    'Library: move the selected comic, or every marked one, to another folder, picked from a list you can type into',
  ),
  addToCollection(
    'Put this comic in a collection, new or one you have; in the library the selected book, or every marked one',
  ),
  markBook(
    'Mark the selected book in the library, or unmark it, for an action on several (move, delete, reset, favourite, collection, upload, remove from S3)',
  ),
  markLeft('Library: mark from where marking started to the cover on the left (Shift+arrows mark a run of comics)'),
  markRight('Library: mark from where marking started to the cover on the right'),
  markUp('Library: mark from where marking started to the cover above'),
  markDown('Library: mark from where marking started to the cover below'),
  markToFirst('Library: mark from where marking started to the first cover'),
  markToLast('Library: mark from where marking started to the last cover'),
  markAll('Library: mark every comic shown, or unmark them all when they are marked already'),
  editBook("Edit the selected book's title, series, issue and creators in the library; on a series, rename it"),
  undo('Undo whatever the notice along the bottom offers to undo, for as long as that notice shows'),
  showSettings('Settings: pages, guided view, cover size, sidecars, touch, back-up and S3 sync'),
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
  const ReaderCommand(this.intent, {this.count, this.register, this.at, this.held = false});

  final ReaderIntent intent;
  final int? count;
  final String? register;

  /// Where a touch landed, so a double-tap zooms in on that spot rather
  /// than the middle of the screen. Keys leave it null.
  final Point<double>? at;

  /// The key is held down and this is its auto-repeat, so a smooth pan
  /// keeps an even speed and stops at the page's edge.
  final bool held;

  /// This command with [intent] in place of its own.
  ReaderCommand as(ReaderIntent intent) => ReaderCommand(intent, count: count, register: register, at: at, held: held);

  /// This command as the auto-repeat of a held key.
  ReaderCommand get asHeld => ReaderCommand(intent, count: count, register: register, at: at, held: true);

  /// The count to act on: a missing count means once.
  int get times => count ?? 1;

  @override
  bool operator ==(Object other) =>
      other is ReaderCommand &&
      other.intent == intent &&
      other.count == count &&
      other.register == register &&
      other.at == at &&
      other.held == held;

  @override
  int get hashCode => Object.hash(intent, count, register, at, held);

  @override
  String toString() =>
      'ReaderCommand(${intent.name}'
      '${count != null ? ', count: $count' : ''}'
      '${register != null ? ', register: $register' : ''}'
      '${at != null ? ', at: (${at!.x}, ${at!.y})' : ''}'
      '${held ? ', held' : ''})';
}
