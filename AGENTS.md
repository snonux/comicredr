# AGENTS.md

Notes for coding agents and contributors working on ComicRedr. The
[README](README.md) is for people using the app; keep it short and put
build internals, test scripts, detector work and conventions here.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the overview with
diagrams (parts, page pipeline, input, detection, the model, data); keep
it in step when the architecture or the model changes.

## Conventions

- Every PR gets a real end-to-end test (see the `tool/e2e_*.sh` scripts
  below) before it is marked ready. If something can't be tested in a
  cloud container (a real phone, a real touchscreen, GNOME Shell), say so
  plainly in the PR.
- Merge with merge commits, not squash, and keep `main` green
  (`make test`).
- The README stays lean and written for a human: a feature list, the
  install steps, a quick start that points to the in-app `?` help, and the
  screenshots. Don't document every key there; the `?` overlay and
  `docs/keys.toml` are generated from the keymap and are the reference.
- README screenshots live in `docs/screenshots/` as WebP, taken from the
  release build. Use only public-domain comics or Pepper&Carrot, and keep
  the credits (David Revoy, CC BY 4.0).
- Test comics are fetched from free sources through the manifests in
  `test/`, never committed. Tag each book with its `style` in the manifest.
- `docs/keys.toml` is generated: after changing intents or default keys run
  `dart run packages/reader_input/tool/write_keys_toml.dart` from the repo
  root (`packages/reader_input/test/keys_toml_test.dart` fails otherwise).
- Version bumps touch `pubspec.yaml`, `lib/src/version.dart` and
  `CHANGELOG.md` together (`test/version_test.dart` checks the first two).
- The app points users at README sections by name: "The CBR files you
  already have" (`lib/src/reader/open_book.dart`) and "The trained
  detector" (`lib/src/library/settings_dialog.dart`). Keep those headings
  or update the strings.

## Cloud container setup

- The Linux e2e scripts need
  `apt-get install libgtk-3-dev xvfb xdotool imagemagick sqlite3 openbox
  x11-utils desktop-file-utils wmctrl` first (xprop for e2e_fullscreen,
  update-desktop-database for e2e_images); most also use Python with
  Pillow, and e2e_margins OpenCV (`pip install opencv-python-headless`).
  e2e_m9 installs from `make tarball`, so run that first.
- The first `flutter build` or `flutter run` downloads PDFium once, so it
  needs the network.
- Cloud sessions can push only their own branch: pushing tags and
  creating releases fails with 403.
- Fetching the corpus needs archive.org, huggingface.co and
  peppercarrot.com. digitalcomicmuseum.com and comicbookplus.com refuse
  cloud containers.
- The ONNX Runtime plugin has no x86_64 Android build, so the detector
  can't run on the Android emulator.

## How the reader works

- The file's first bytes decide the format, not its extension. Progress,
  panels and bookmarks are keyed on the content (SHA-1 of the first 64 KiB
  plus the size), so they follow a renamed or copied file.
- PDFs render through PDFium at the size they are shown at, capped at
  300 dpi: about a quarter of a second a page at screen size, just under a
  second at the 2048 px guided view asks for. The current page renders
  before prefetched ones.
- Two-page mode shows a page at least 1.1 times wider than tall (a
  scanned double-page spread) alone and starts pairing again after it
  (`unitAt` in `lib/src/reader/layout.dart`). The sizes come from the page
  headers (`ComicDocument.pageSizes`, `imageSize`), read after the book
  opens: about 30 ms for a 36-page CBZ, inflating only each page's first
  64 KiB. EXIF rotation is not looked at.
- Folder books read JPEG, PNG, WebP, GIF and BMP in natural order,
  subfolders included, skipping dotfiles and `Thumbs.db`. CBZ and CBT
  (tar) use the same order; a CBT is indexed once on open (GNU long names,
  pax and v7 headers) and each page is one seek.
- An EPUB is a ZIP whose `mimetype` entry says so (or that has
  `META-INF/container.xml`). Pages follow the OPF spine: an image item is
  a page, an XHTML or SVG item is the largest image it points at, items
  without an image are skipped. Fewer than half the spine as pages, or
  pages with paragraphs of text (unless the book is `pre-paginated`), and
  the book is refused as a text ebook. Metadata comes from a ComicInfo.xml
  inside, else the OPF (Dublin Core, `belongs-to-collection`,
  `calibre:series`, creator roles `ill`/`art` as artists).
- A PNG, JPEG or WebP file (sniffed by its first bytes) is a one-page
  comic, `ImageDocument`. In the library a folder is a folder book when it
  holds page images directly and no comic file anywhere under it
  (`isFolderBook`); otherwise each loose PNG/JPEG/WebP in it is its own
  book. GIF and BMP are only ever pages. The launcher lists the image types
  and `inode/directory` for Open With; `linux/packaging/keep-viewer.sh`
  pins the previous default viewer and file manager when installing into
  `~/.local` would otherwise take them over.
- A folder given on the command line, by Open With, a drop or `O` opens as
  a book when `findBooks` sees it as one folder book; otherwise, when
  books are under it, the Folders tab opens at it (`HomeScreen._openPath`),
  adding it as a library folder unless one already holds it. `--add-root`
  only adds, so the e2e scripts start on the usual tab.
- App data (`appDirs`, `lib/src/data/data_dirs.dart`): on Linux, when
  `~/Comics` exists and there is no `comicredr.sqlite` in
  `~/.local/share/org.snonux.comicredr` (or `$XDG_DATA_HOME`, or the old
  executable-named folder), the index database, installed models,
  `cache/` (covers, thumbnails) and `keys.toml` all go in
  `~/Comics/.comicredr/`; otherwise the XDG folders as before. Decided at
  every start from what is on disk, nothing migrated. `keys.toml` and
  models in the XDG places are still read as a fallback, and the Makefile
  (`APPDATA`, `MODELDIR`, `KEYS`) uses the same rule. The scanner skips
  dot folders and the watcher ignores `.comicredr`. Android keeps its
  private folders. `?` shows the folder (`appDataDirProvider`). A
  `~/Comics` symlink to a folder counts (`.comicredr` lands in the real
  folder, the library folder keeps the link's path); a dangling one doesn't.
- Every start, while the library has no folder at all, `~/Comics`
  (Android: `/storage/emulated/0/Comics`, once All files access is
  granted, also checked on resume) is added if it exists
  (`addDefaultFolder`, `lib/src/library/default_folder.dart`). It runs
  after `--add-root`, so the e2e scripts are unaffected. Taking it out of
  the library sets `library.defaultFolderRemoved` and it stays out.
- The library's first scan reads each book once in the background (about a
  third of a second a book); later starts only compare sizes and dates. A
  watcher picks up file changes; `R` rescans; Android rescans on resume.
- Panels are detected in the background, starting at the current page,
  and cached in the app database and the book's sidecar. A confidence gate
  shows the page whole when the panels don't look like a real layout; the
  status line says why. A page is analysed again when the model file
  changes.
- A whole-library detection pass runs after each scan at low priority,
  resumes after a restart, and is off by default on Android. Settings turns
  it off.
- The detector model is built into the app from
  `assets/models/comicredr-panels.onnx` (committed: D-FINE-S, Apache-2.0,
  see "Train the detector"; `make model MODEL=...` swaps in another file).
  `make` and `make apk` refuse to build without it unless
  `NO_MODEL=1`. `findModel` (lib/src/reader/model_detector.dart) looks, in
  order, at `COMICREDR_MODEL=/path/to/file.onnx` (`none` forces classic
  CV), a user-installed model in the app data folder's `models/` (`~/Comics/.comicredr/models/` or `~/.local/share/org.snonux.comicredr/models/`)
  (`make install-model`; on the phone also
  `Android/data/org.snonux.comicredr/files/models/`, `make push-model`),
  then the built-in one. Because an installed model wins, `make install`
  moves one that differs from the built-in file aside (`.onnx.old`,
  `_retire-models`), and `make install-apk` does the same on the phone, so
  a plain `make && make install` always runs the model it was built with.
  On Linux the built-in file is opened in place in
  `bundle/data/flutter_assets/assets/models/`; on Android it is copied out
  of the APK into `<app support>/bundled-model/` once per model version.
- Sidecars: `.book.cbz.crdb` beside the file, `.comicredr.crdb` inside a
  folder book; both hidden. One under the old visible name
  (`book.cbz.crdb`) is renamed on open, scan, reset or move
  (`adoptLegacySidecar`), merged into the hidden one when both exist.
  They hold metadata, panels and balloons, bookmarks, marks, collections
  and per-device positions. Removed bookmarks stay removed
  when an older sidecar comes back. Unwritable folders fall back to the
  app database; Settings → Export sidecars writes them to a tree elsewhere.
  `X` (or Reset in the book's details) resets a comic: `SidecarSync.reset`
  deletes its rows and rewrites every copy's sidecar without them, since a
  sidecar left alone would merge them straight back in.
  Delete (`gd`, Shift+Delete, or the button in the book's details;
  `lib/src/library/delete_book.dart`) asks first with Cancel focused,
  closes the book, then `SidecarSync.forget` flushes and stops writing
  its sidecar and returns every copy of it (`sidecarsOf`). The comic goes
  first, for good and not to the trash (snonux's choice); if that fails nothing else changes. Then its sidecars,
  and `LibraryStore.forgetDeleted` drops the file's row, and when no other
  copy of the content key is left, every row about it plus its cover and
  page thumbnails.
  Metadata edits (`e`, `lib/src/library/edit_dialog.dart`) are rows in
  `overrides`, field to a JSON `MetaEdit` with a time; the later edit per
  field wins a sidecar merge, and an undo is a row too, so it travels.
  `LibraryStore.books()` lays them over the file's facts; the comic file is
  never rewritten, since that would change its content key.
  Settings → "In one folder" (`sidecars.dir`, per install) keeps them all
  in one folder instead, laid out like the library by root folder name
  (`storedSidecarPath`; books outside the library go under `elsewhere/`).
  One left beside a comic is still read and merged; switching offers to
  move them, merging into a sidecar already there. Anything that finds a
  book's sidecar goes through `SidecarSync.sidecarsOf`/`sidecarFor`.
  Inspect one with
  `sqlite3 '.book.cbz.crdb' 'select page, kind, x, y, w, h from panels'`.
- Bookmarks and vi marks are rows in `bookmarks` (mark null for a
  bookmark, panel null for a whole page). The reader follows the open
  book's rows through `LibraryStore.watchBookmarks`, so the list (`M`,
  `lib/src/reader/bookmark_list.dart`), the ribbon, the progress bar's
  notches and `}` `{` see changes from anywhere. `mm` takes off whatever
  `ReaderState.bookmarksHere` holds, else adds one. A note
  (`LibraryStore.setNote`) replaces the row with a new id and removes the
  old one, which the sidecar merge's "union by id, removal wins" carries
  to every copy.
- Favourites are the ordinary collection named `Favourites`
  (`favouritesCollection` in `library_store.dart`), so they travel in the
  sidecar under the collection rule. `*` (`toggleFavourite`) adds or takes
  out the open book or the selected cover; `gf` (`showFavourites`), or the
  header's star, opens that collection on the Collections tab
  (`LibraryScreenState._favourites`), where `*`, `x` and the details' star
  take a comic out with an Undo notice. Renamed or emptied, the next
  favourite makes the collection again.
- Touch: `ReaderTouch` looks every gesture up in a `TouchMap`
  (`reader_input` touch_map.dart): taps, double-taps and long presses on a
  3x3 grid (30% side columns, rows in thirds), four swipes and a
  two-finger tap, each mapped to a ReaderIntent. The map is the preset
  picked in Settings (`touch.preset`) with the `[touch]` lines of
  keys.toml over it. A tap only waits for a possible second tap in a zone
  that has a double-tap action, so edge taps turn at once. Pinch zoom and
  panning stay with the InteractiveViewer and can't be remapped.
- Page thumbnails (the `p` grid and the progress bar's preview) come from
  `Thumbnails` in `lib/src/reader/thumbnails.dart`: made on demand through
  the book's own document (so PDFs use the shared PDFium isolate), scaled
  by Flutter's decoder, JPEG-encoded on a short isolate and kept in
  `<cache>/covers/pages/<content key>/<page>.jpg`. Newest request first,
  two at a time; tiles evict their images when they scroll away.
- Shuffle (`S` on the Folders tab, `gs` picks again; setting
  `library.shuffle`): each book tile shows page `shufflePage(key, pages,
  seed)` instead of its cover, never page 1, from a seed made anew when
  shuffle turns on, a folder is entered or `gs`, so scrolling keeps the
  picks. `ShufflePages` (`lib/src/library/shuffle.dart`) makes them into
  the page grid's thumbnail files (`<cache>/covers/pages/<key>/<n>.jpg`,
  256 px) for tiles on screen only, newest first, two at a time; each opens
  the book through `BackgroundDocument` and closes it straight after. The
  cover shows until the page is ready. On a phone-wide header the
  reshuffle button is left out; `gs` or `S` twice picks again.
- The details view (`I`, `lib/src/reader/comic_details.dart`, gathered by
  `readComicReport` in `comic_report.dart`) reads no pixels: each page's
  format, size, bytes and JPEG quality come from `ComicDocument.pageFacts`
  (the header, as `pageSizes` reads it; quality estimated from the
  luminance quantisation table the way libjpeg scales it), through the
  book's own worker, so a PDF stays on the PDFium isolate. A PDF's images
  come from `pdfImages` (comic_formats), which scans the file's bytes for
  image XObjects on a short isolate, no PDFium: about 50 ms for 10 MB.
  Both are cached per content key for the session. Detection numbers are
  `PanelStore.load` for this install's detector, judged by the same gate
  guided view uses.
- Scan clean-up (`c`): `findLevels` (comic_analysis `cleanup.dart`) reads
  the paper colour off the 240 px copy auto-trim also measures, and the
  page is drawn through that colour matrix, so it costs nothing to show.
  `upscaleSharpen` (unsharp mask, then Catmull-Rom) runs in an isolate
  from `PageCache` when a page is smaller than its box, or a zoom tile
  asks for more than the stored page has (up to twice its width); the
  sharpened copy is cached under its own key. About 40 ms per output
  megapixel on one core: 40 to 110 ms a zoom tile of a 1000 px scan.
  Detection decodes its own copy, so it never sees the clean-up.
  `dart run tool/cleanup_ppm.dart in.ppm out.ppm 2` (in comic_analysis)
  tries it on one page.
- A page guided view shows whole (no panels that pass the gate) holds
  for one step: the first step onward stays and sets `ReaderState.held`,
  the next one turns, however soon. Mirrored going back. The cue
  (`guided.pauseCue`, `gw` cycles it) is the Scaffold background turning
  `heldColour` (#3A0D16) in app.dart until the page is left, the default,
  or ReaderView's zoom pulse (colour instead with reduced motion). The
  status line explains the first three. A page arrived on from the other
  side, a count (`3l`) and pages whose panels are not known yet are not
  held (`_pauseOnWhole` in `reader_notifier.dart`). `W` or Settings turns
  it off (`guided.pauseWhole`).
- Parts of a page (`H1` `H2`, `B1`-`B3`, `Q1`-`Q4`, `lib/src/reader/region.dart`):
  `ReaderState.region` is the split, the part and the page of the unit it
  is on. ReaderView frames it with guided view's camera and dim, in guided
  view or out of it (`_aimCamera`). Steps go through the parts in reading
  order, across a spread's other page, then to the whole page; in guided
  view that whole page is held like a page without panels. Leaving the
  page, a mode switch, Esc or the same keys end it.
- Turning the comic (`>`, `<`, `gr`; `ReaderState.rotation`, quarter
  turns clockwise): ReaderView puts its whole view in a `RotatedBox`, so
  layout, fit, guided view's camera and dim, zoom tiles and page parts all
  work in the turned frame, whose viewport is the screen with its sides
  swapped. Only what crosses to the screen is turned: a tapped point
  (`_unturned`), the transform the touch layer reads, `j` `k` (`_pan`),
  the fit (`_frameFit`: fit width on a quarter turn fits the frame's
  height), where a new page starts (`_home`, the page's top left as seen)
  and `H1`-`Q4` (`unturnRect`). Panels stay in page coordinates and
  detection never sees the turn. Saved per book in the position's
  `view_json` (`rotation`), so it travels in the sidecar. Page thumbnails
  are not turned.
- Non-rectangular panels: the detector outputs boxes; `refineOutlines`
  traces the real outline along the gutter and the reader dims outside
  it, while the camera frames the box.
- A resize or rotation keeps the page, the zoom and the point in the
  middle of the screen; guided view re-frames the same panel. Pages
  decode again at the new size a quarter second after the size settles.
  Android handles rotation in the running activity (`configChanges` in
  the manifest), so nothing restarts.
- Fullscreen (`f`, F11, a status-line button, a tap in the middle):
  `ReaderState.fullscreen`, in the library as in the reader, saved as
  `reader.fullscreen` and loaded at launch and when a book opens. `HomeScreen._applyFullscreen` makes the window follow: on
  Linux through the `org.snonux.comicredr/window` channel in
  `linux/runner/my_application.cc` (`gtk_window_fullscreen`, which also
  hides the GNOME header bar; a `window-state-event` reports the window
  manager leaving fullscreen back as `fullscreenChanged`), on Android
  immersive mode. In fullscreen the page keeps the whole screen; the
  status line and progress bar come over it on a notice, while keys are
  typed, or while the mouse is in the bottom 96 px, and the pointer hides
  1.5 s after the mouse stops. The library keeps its tabs and search in
  fullscreen. Esc keeps its meanings (guided view, the book, the search, a
  folder up) and leaves fullscreen only when the library has nothing left
  to back out of (`LibraryScreenState.handle` returns false).
- The time (`T`, and a long press in the middle zone of every touch
  preset): `ReaderIntent.showTime`, handled in `HomeScreen._onCommand`
  before the library or reader see it, flashes `ClockFlash`
  (`lib/src/reader/clock_flash.dart`) over everything for 2 s, then a
  0.6 s fade (none with reduced motion). It sits in an `IgnorePointer`
  and formats with `MediaQuery.alwaysUse24HourFormat`. No setting.
- Android needs All files access (MANAGE_EXTERNAL_STORAGE), granted on a
  settings page. The APK was tested on an Android 14 emulator only; a real
  phone, pinch zoom and real speed and memory are untested.
- `make install` puts the bundle in `~/.local/lib/comicredr`, a symlink in
  `~/.local/bin` and the launcher and icons in `~/.local/share`; it never
  runs Flutter, so `sudo make install PREFIX=/usr/local` is safe, and
  `DESTDIR` is supported. `APK_ABI=android-arm64,android-x64` adds the
  emulator ABI to `make apk`. `make push-keys` copies keys.toml to the
  phone.

## Layout

```
lib/                      Flutter app: library, reader screen, page cache, keyboard layer, Drift index
packages/comic_formats    ComicDocument, the CBZ, CBT, EPUB, PDF and folder adapters, the worker isolate, sniffing, sort
packages/comic_analysis   Panel model, classic-CV detection, reading order, the confidence gate
packages/reader_input     ReaderIntents, default keymap, vi key-sequence resolver
spike/                    M1 throwaway: classic-CV panel detection and overlays
test/corpus.manifest.toml Free test comics, fetched into git-ignored test/corpus/
```

## Develop and test

The e2e scripts use the detector built into the release build (and pass
its file where they need one); `COMICREDR_MODEL=file.onnx` tries another,
`COMICREDR_MODEL=none` forces classic CV.

```sh
make dev                         # debug build with hot reload (r in the terminal)
make test                        # analyzer and every test
dart run build_runner build -d   # regenerate Drift code after schema edits
flutter analyze && flutter test
for p in packages/*; do (cd $p && dart test); done   # make test runs all three
make version                     # the version in pubspec.yaml; bump lib/src/version.dart and CHANGELOG.md with it
make icons                       # re-render linux/packaging/icons/*.png after editing the SVG
(cd packages/comic_analysis && dart run tool/detect_pgm.dart page.pgm)  # Dart detector on one page, to compare with spike/detect_cv.py
tool/e2e_linux.sh [book.cbz|book.pdf|folder]  # release build under Xvfb, driven by real keys incl. guided view and by injected GTK touches, screenshots in build/e2e/
tool/e2e_modern.sh            # guided view on real modern comics from test/corpus-modern, screenshots in build/e2e-modern/
tool/e2e_library.sh           # library over the fetched corpus: scan, covers, series, search, ] [, bookmarks, live folder changes, restart, phone layout and touch; checks the index with sqlite3
tool/e2e_sidecar.sh a.cbz b.pdf folder/  # two installs as laptop and phone: sidecar written, copied and renamed, re-linked, resumed without detecting, position offered back; plus a read-only shelf
tool/e2e_m8_library.sh        # collections made from book details, a sitting in the history, the settings dialog, a restart; checks the index and a sidecar with sqlite3
tool/e2e_resume.sh book.cbz   # closes and reopens the release build mid-panel, mid-balloon, zoomed, and killed; fails if the view differs
tool/e2e_margins.sh           # guided view on eval pages padded with a wide scanned margin; checks the index records the trim
tool/e2e_whole_page.sh book.cbz [page]  # guided view's whole-page steps with keys and touches, both ways, w on and off, across restarts; fails if a step shows the wrong view
tool/e2e_library_detection.sh [corpus] [model]  # whole-library panel pass: starts by itself, resumes after a kill, fills sidecars
tool/e2e_m9.sh book.cbz       # release tarball + install.sh, keys.toml, auto-trim, night filter, ? search, across restarts
tool/e2e_touch_zones.sh       # tap zones: standard taps, gt, Left-handed picked in Settings, a keys.toml [touch] section with a long press, vertical swipes and a two-finger tap; checks the index with sqlite3
tool/e2e_pages.sh book.cbz book.pdf  # page grid by key, scrubber hover, drag and click, the PDF grid, thumbnails reused after a restart, grid zoom with + and Ctrl+wheel kept across a restart
tool/e2e_cleanup.sh [low.cbz] [big.cbz]  # c on golden-age scans: before/after, zoomed, guided, across a restart; prints the clean-up times
tool/e2e_resize.sh book.cbz   # resizes the window while zoomed, mid-drag and in guided view, then back; fails if the view differs
tool/e2e_hidden_sidecars.sh   # sidecars written hidden; a fresh install renames old visible ones and merges a pair, keeping bookmarks and position; makes its own books
tool/e2e_sidecar_dir.sh       # Settings → In one folder via the GTK picker: sidecars moved there and back, a fresh install reads them; makes its own books
tool/e2e_spreads.sh book.cbz [spreads.pdf]  # two-page mode with a scanned spread joined into the book: pairing around it, full height, reopen, guided view; a PDF of wide pages (I, Villain) steps page by page
tool/e2e_reset.sh book.cbz     # X: redo panels, then reset everything from the reader, then from the library's book details; checks the index and the sidecar
tool/e2e_open_folder.sh       # comicredr FOLDER: inside the library, outside it (added), a folder book and a CBZ still read; Backspace up
tool/e2e_default_folder.sh    # ~/Comics as the default library folder, fresh HOMEs: with it, without it (empty library, Settings from there, made later), taken out and restarted, a folder of one's own; makes its own books
tool/e2e_folders_live.sh      # Folders tab open while comics, sub-folders and the shown folder are added, moved and deleted
tool/e2e_formats.sh           # CBT and EPUB: real files from test/formats.manifest.toml; library, same pixels as the CBZ, refused ebooks
(cd packages/comic_formats && dart run tool/inspect_book.dart book.epub)  # what the format layer makes of a book, or why it refuses it
tool/e2e_bookmarks.sh book.cbz  # mm on and off, a guided panel bookmark, } {, the M list with a note, the library's Bookmarks tab, the sidecar, a fresh install, phone layout
tool/e2e_images.sh            # one-page PNG/JPEG/WebP comics: library, guided view, sidecars, ], the launcher's Open With without taking the image default
tool/e2e_pause_whole.sh book.cbz [page]  # a page shown whole holds one step with the wine-red and the zoom cue (gw), keys and touches, both ways, a count, W across a restart (reptisaurus-v2-005 page 3)
tool/e2e_fullscreen.sh        # f and F11 under Openbox in Xvfb, plain and posing as GNOME Shell (header bar): window state, only the page, pointer, bottom edge, Esc, restart; makes its own book
tool/e2e_clock.sh            # T and a long press show the time for 2 s: fullscreen, windowed, the library; fades; makes its own book
tool/e2e_details.sh book.cbz book.pdf  # I: details over the reader, scrolled, a page picked from the list, a PDF's images, from the library
tool/e2e_favourites.sh        # * from the reader and on a cover, gf and the header star, x takes one out, a restart; checks the index and a sidecar with sqlite3; makes its own books
tool/e2e_data_dir.sh          # app data in ~/Comics/.comicredr with fresh HOMEs: with ~/Comics, without it, an existing XDG database kept, ~/Comics a symlink (taken out stays out), a dangling one; nothing else written, .comicredr not in the library; makes its own books
tool/e2e_delete.sh             # gd and Shift+Delete: cancelled by Enter and Esc, then confirmed from the reader and the library; checks nothing lands in the trash, sidecars, index and thumbnails; makes its own books
tool/e2e_edit.sh a.cbz b.cbz folder/  # e: edit a book into another series, rename the series, restart, a second install reads the edits from the sidecars; checks both indexes and the sidecars
tool/e2e_shuffle.sh           # S and gs on the Folders tab over two CBZs, a PDF and a folder book: pages not covers, stable while moving, reshuffled, a book opens on page 1, kept across a restart
tool/e2e_search_key.sh        # / on the Folders tab: search, a click into a folder with the cursor in the box, / again selects the search, Enter, Esc; makes its own books
tool/e2e_rotate.sh            # > < 2> gr on a made book of coloured panels: the page turned, guided view across pages, zoom and j, a restart (index and sidecar), another book upright
tool/e2e_regions.sh book.cbz [page]  # H1 H2, B1-B3, Q1-Q4 on a page shown whole, in guided view and out: each part framed (tool/region_check.py), stepped, held, Esc; reptisaurus-v2-005 page 3
```

## Detection spike (M1)

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics
python3 spike/make_synthetic.py                       # synthetic pages with ground truth
python3 spike/fetch_corpus.py --manga109-model        # real comics + the Manga109 model (comparison only)
python3 spike/extract_pages.py test/corpus spike/pages
cd spike && python3 run_spike.py pages out --weights ../test/corpus/models/<model>.pt
```

`out/contact.jpg` shows every overlay: green boxes passed the confidence
gate, red ones fell back to plain paging, blue are the pretrained detector's
frames, magenta its balloons. Pages are sampled into one folder per style
(from the manifest's `style` field), `out/contact-<style>.jpg` puts classic
CV and the pretrained model side by side for each style, and `results.json`
carries a per-style summary.

## Train the detector

The model built into the app is D-FINE-S (Apache-2.0 code and weights),
fine-tuned from its COCO-only checkpoint (`ustc-community/dfine-small-coco`
on Hugging Face) on our own labels, and committed at
`assets/models/comicredr-panels.onnx`. Keep it clean: no Ultralytics code
or weights (they are AGPL, trained models included), no Objects365
checkpoints (academic use only) and nothing trained on Manga109. Only
public-domain, CC0 and CC BY books go in `test/train.manifest.toml`, each
credited in NOTICE; NC, ND and share-alike books live in
`test/train-local.manifest.toml` with labels in `spike/labels/train-local/`,
for a model kept at home. The test sets (`test/corpus.manifest.toml`,
`test/modern.manifest.toml`) only score models and never ship.

Everything runs on the CPU. `make train-model` (tool/train_model.sh) runs
the steps that build the shipped model, from fetching the training comics
to exporting the ONNX file, then validates it and puts it in
`assets/models/` through tool/fetch_model.sh (the check loads the file with
onnxruntime and wants a [1, 300, 6] output). The export folds constants
with onnxslim, without which the ONNX Runtime 1.15 the app bundles cannot
load it. The labels are committed in `spike/labels/` (how they were drawn:
`spike/LABELLING.md`); the comics are fetched.

```sh
pip install opencv-python-headless numpy pillow pypdfium2 torch transformers onnx onnxruntime onnxslim
python3 spike/fetch_corpus.py                                   # eval comics
python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train
python3 spike/fetch_corpus.py --manifest test/modern.manifest.toml --out test/corpus-modern
python3 spike/fetch_corpus.py --manifest test/diagonal-eval.manifest.toml --out test/corpus-diagonal-eval
python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 400
python3 spike/extract_pages.py test/corpus-train spike/train_pages --per-book 400 --manifest test/train.manifest.toml
python3 spike/extract_pages.py test/corpus-modern spike/modern_pages --per-book 400 --manifest test/modern.manifest.toml
python3 spike/extract_pages.py test/corpus-diagonal-eval spike/diagonal_pages --per-book 400 --manifest test/diagonal-eval.manifest.toml
python3 spike/labelkit.py import spike/labels/eval spike/eval_pages
python3 spike/labelkit.py import spike/labels/train spike/train_pages
python3 spike/labelkit.py import spike/labels/modern spike/modern_pages
python3 spike/labelkit.py import spike/labels/diagonal-eval spike/diagonal_pages
python3 spike/synth_modern.py spike/train_pages spike/synth_pages --count 400 --seed 1
python3 spike/train.py spike/train_pages spike/synth_pages --out spike/out/train --epochs 30 --imgsz 640   # -> spike/out/train/last/
python3 spike/train.py --export spike/out/train/last --out-onnx spike/out/comicredr-panels.onnx
cd spike && python3 evaluate.py eval_pages --out out/eval --no-cv --trim \
    --trained out/comicredr-panels.onnx                          # out/eval/report.md
```

`labelkit.py candidates PAGES --weights model.onnx` suggests boxes from any
model in the app's format when labelling new pages.

`synth_modern.py` cuts art out of the labelled frames of the training
pages and lays it out again as modern pages (grids without gutters,
slanted gutters, panels on black, rounded and round frames, tilted
collages, bleeds), with exact labels; a placement that would cut a
balloon in half is tried elsewhere. The clean training set has few modern
indie books, and these pages make up for part of that.

`evaluate.py` scores classic CV and a trained model on the same 100 labelled pages, none of them from a training
book: panel and balloon F1 at IoU 0.5, and per page whether guided view
would move the camera right, show the page whole, or move it wrong. Like
the app, it finds slanted frames' outlines before the gate
(`--no-outlines` to judge by boxes).

Results (2026-09-26, `--no-cv --trim`), guided right / whole / wrong on
the original 100, the modern 66 and the diagonal 24 eval pages
(`test/diagonal-eval.manifest.toml`), with balloon stops on captions:

| Model | Original | Modern | Diagonal | Balloon stops on captions |
|---|---|---|---|---|
| Old YOLO26s (Manga109 start, not shipped) | 67 / 20 / 13 | 48 / 15 / 3 | 6 / 9 / 9 | 20 / 13 |
| D-FINE-S, 884 clean pages | 71 / 22 / 7 | 40 / 22 / 4 | 4 / 19 / 1 | 25 / 19 |
| D-FINE-S, 998 clean pages | 69 / 22 / 9 | 43 / 21 / 2 | 6 / 13 / 5 | 23 / 26 |
| D-FINE-S, 998 + 400 synthetic (shipped) | 73 / 17 / 10 | 47 / 15 / 4 | 4 / 15 / 5 | 14 / 23 |

About 150 ms a page on 4 cores in ONNX Runtime 1.15. The diagonal pages
shown whole mostly have every panel found, but slanted panels whose boxes
overlap and whose outline the tracer can't find (pencil art on grey paper,
dark gutters) fail the gate. IHOW's rounded frames on black are still
missed.

The sections below are the history of the earlier YOLO26s models, which
started from a Manga109-trained checkpoint and are no longer shipped.

Results on the 100 eval pages (2026-09-24, 4-core CPU):

| Detector | Guided right | Whole page | Wrong camera | Panel F1 | Balloon F1 | ms/page |
|---|---|---|---|---|---|---|
| Classic CV | 29 | 12 | 59 | 0.55 | none | 73 |
| Manga109 model as is | 59 | 34 | 7 | 0.83 | 0.53 | 511 |
| Fine-tune, float ONNX (38 MB) | 64 | 25 | 11 | 0.87 | 0.81 | 103 |
| Fine-tune, INT8 ONNX (10 MB) | 46 | 42 | 12 | 0.78 | 0.77 | 111 |

The float model is the one to install: INT8 loses accuracy and is no
faster here. Its wrong pages are mostly one missed narrow caption panel on
dense golden-age pages, plus one page whose panels are all right but read
in a debatable order. Black-and-white and modern indie art stay weakest.

**Modern layouts (2026-09-24).** A second test set, `test/modern.manifest.toml`
(labels in `spike/labels/modern/`), holds 66 pages from six modern books
never trained on (NASA's First Woman, the CDC's Zombie Pandemic, Wolf's
Head, I Villain, IHOW, Stigkland) plus four Pepper&Carrot episodes, tagged
modern-digital, modern-indie and modern-painted. The shipped model guided
37 of them right: it missed panels, or reported a whole row as one more
panel, and the gate then showed the page whole. The retrain adds 84
labelled modern pages to the training set (305 pages, 45 epochs, about two
hours on 4 cores), drops a frame that wraps two others, lowers the frame
threshold to 0.3 and reads two-page spreads page by page:

| Test set | Model | Guided right | Whole page | Wrong camera | Panel F1 |
|---|---|---|---|---|---|
| Modern, 66 pages | first fine-tune | 37 | 22 | 7 | 0.81 |
| Modern, 66 pages | modern retrain | 49 | 15 | 2 | 0.87 |
| Original, 100 pages | first fine-tune | 64 | 25 | 11 | 0.87 |
| Original, 100 pages | modern retrain | 67 | 20 | 13 | 0.87 |

Per style on the modern set: digital 9 to 14 of 18, indie 17 to 24 of 36,
painted 11 of 12 either way. Still missed: IHOW's rounded frames on black
(0 of 9, nothing like it in training).

**Frame outlines (2026-09-24).** `refineOutlines` (Dart, in
`packages/comic_analysis`) and its Python twin `spike/outlines.py` find
the outline of non-rectangular frames. On the labelled sets (379 pages,
2,181 frames) they reshape 52 frames: 11 of 292 modern, 14 of 440 in the
original set and 27 of 1,449 in training. Every one was checked by eye;
none cuts into a panel's own art. About 9 more non-rectangular modern
frames are missed, mostly a collage page of tilted thin-lined panels in
I Villain. `python3 spike/outlines.py eval PAGES --crops DIR` writes a
review crop of each reshaped frame.

**Wide scanned margins (2026-09-24).** A page scanned with a wide blank
margin was shown whole: its frames covered too little of the page for the
confidence gate. When trimming would leave at most 80% of a page, the
model now looks at the page with the margin cut off (the same measure as
`t`, leaving 3% of paper) and the gate judges the frames against that
part; the trim is stored with the run. `evaluate.py --trim` does the same,
and `--add-margin 0.12` pads every page first (`--margin-colour 30,30,30`
for a dark scanner bed). Guided right / whole / wrong:

| Test set | Before | Trimmed |
|---|---|---|
| Original, 100 pages | 67 / 20 / 13 | 67 / 20 / 13 |
| Original, 8% margin added | 44 / 54 / 2 | 67 / 20 / 13 |
| Original, 12% margin added | 28 / 72 / 0 | 68 / 20 / 12 |
| Original, 12% dark margin | 28 / 67 / 5 | 64 / 32 / 4 |
| Modern, 66 pages | 49 / 15 / 2 | 49 / 15 / 2 |
| Modern, 8% margin added | 36 / 27 / 3 | 47 / 15 / 4 |
| Modern, 12% margin added | 16 / 49 / 1 | 46 / 16 / 4 |

The wrong pages with a margin are the ones the model gets wrong without
one; the margin used to hide them. Trimming every page, even a thin
margin, changed the model's answer on a few pages for no gain (modern: 47
right instead of 49), hence the 80% rule. Classic CV keeps the whole page:
trimmed, it passed the gate with wrong frames on 43 more of the padded
pages while getting 8 more right.
