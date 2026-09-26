# Changelog

Versions follow [semantic versioning](https://semver.org). The version
lives in `pubspec.yaml`; `make version` prints it, `comicredr --version`
reports it, and the app shows it in the library's status line and in
the `?` overlay.

## Unreleased

- **Android tablets:** ComicRedr now makes good use of a tablet. The
  reader's status line has a button for two pages side by side (`d`),
  which fills a tablet held sideways; on a small tablet or in split
  screen the page counter comes first and is no longer cut off, and the
  library's search box is no longer squeezed. More decoded pages are
  kept in memory on a tablet's bigger screen, so page turns stay quick.
  The guide and install docs cover tablets.
- **Panels only for the comic you read:** ComicRedr no longer works
  through the whole library in the background. It finds the panels of
  the open comic, from the page you are on to the end, with guided view
  on or off, and stops when the comic is closed. The library's
  "Finding panels" line, its pause button and the setting are gone. The
  same on Linux and Android.
- **Touch on Linux:** the status line starts with a back arrow, so a
  Linux touchscreen can leave guided view and the comic the way the
  phone's back gesture does. Every other gesture already worked there;
  `tool/e2e_touch_linux.sh` now checks all of them by touch alone.

## 0.2.1

Android fixes.

- **Open a comic (`o`) opens the file where it is:** the system picker
  now hands back the file's real path instead of a copy in the app's
  cache, so big PDFs no longer run it out of memory, and the position,
  sidecar and Delete apply to the real comic. Open a folder (`O`) works
  for SD cards too.
- **Android 7 to 10:** the app asks for storage access, so the library
  is no longer empty there.
- **System bars:** the reader's status line and progress bar stay clear
  of the navigation bar (Android 15 and after leaving fullscreen), and
  back leaves fullscreen first.
- **Phone layout:** the status text gets its own line above the buttons,
  Settings labels and the Collections tab ("Groups") no longer break
  mid-word, and a hardware keyboard no longer draws a green frame round
  the app.
- **Smaller APK:** only the ABIs built for are packed (the arm64 APK is
  about 10 MB smaller), so a 32-bit phone is no longer offered one that
  crashes.

## 0.2.0

- **The panel detector is built in and open:** a new D-FINE-S model,
  trained only on public-domain and CC BY comics, now ships in the
  repository and in every build, under Apache 2.0 like the rest of
  ComicRedr (LICENSE, NOTICE). No more `make model` step. It learned from
  998 labelled pages, including 37 books with slanted, curved,
  wedge-shaped and irregular frames and 7 modern indie books, plus 400
  synthetic modern pages laid out from their art, and nothing
  in it comes from Manga109 or Ultralytics.
  Narration captions are their own class, so balloon mode stops only on
  speech and thought balloons. Panels are detected again on first open.
  `make install` and `make install-apk` move a model installed earlier
  with `make install-model` or `make push-model` aside (`.onnx.old`), so
  the built-in one is used without any other step.

- **Turn the comic (`>`, `<`, `gr`):** a quarter turn clockwise or
  counter-clockwise, with a count for more (`2>` turns it upside down),
  and `gr` back upright. Guided view frames its panels on the turned page,
  zoom, `j` `k`, fit width and `H1`-`Q4` follow the screen, and the turn
  is kept for that comic with its position, in the sidecar too.

- **Everything in ~/Comics:** on Linux, when `~/Comics` exists and the app
  has no database in `~/.local/share` yet, it keeps its database, covers,
  thumbnails, `keys.toml` and installed models in `~/Comics/.comicredr/`,
  so all of it lives in one folder with the comics. Existing installs stay
  where they are; Android is unchanged. `?` names the folder.

- **The time at a glance (`T`, or a long press in the middle of the
  page):** the current time, large and centred on a dim backing, for two
  seconds, then it fades away; in the library, the reader and fullscreen.
  It follows the system's 12 or 24 hour setting and takes no taps.

- **Hidden sidecars:** a comic's sidecar is now `.book.cbz.crdb`, a
  hidden file, beside the comic and in the one sidecar folder alike (a
  folder book's `.comicredr.crdb` already was). A sidecar under the old
  visible name is renamed the next time the comic is opened or scanned,
  keeping its panels, bookmarks and positions; when both names exist the
  two are merged.

- **Zoom the page grid:** in the `p` grid, `+` and `-` (or Ctrl and the
  scroll wheel, a pinch, or the header's buttons) go from many small
  thumbnails to one page a row, keeping the selected page in view. Bigger
  tiles get sharper thumbnails (512 or 1024 px, made when first needed),
  and the size is remembered.

- **Comic details (`I`, the info button on the status line, or Details
  in the library):** the file (format as its bytes say, size, content key,
  sidecar), the pages (pixel sizes, wide spreads, what they are stored as,
  JPEG quality estimated from the quantisation tables, how sharp they are
  on this screen; for a PDF its page size and the scanned images inside,
  read from the file), metadata with hand edits marked, progress and time
  read, and detection: the detector, pages analysed, panels, balloons and
  captions found, why pages are shown whole, confidence and time, and
  every page on its own line. A page picked in the list is gone to, and
  Redo panels finds the comic's panels again. Only page headers are read.

- **Rebuilding the detector:** `make train-model` rebuilds the model from
  the free training comics on the CPU and checks the file before the
  build packs it.

- **Bookmarks you can use:** `mm` (or the bookmark button) now takes a
  bookmark off again when the page, or in guided view the panel, already
  has one, instead of adding another. A ribbon at the top right of the
  page and amber notches on the progress bar show where bookmarks are.
  `M` (or the list button) lists the book's bookmarks and marks with a
  picture of each page: Enter or a tap jumps, `e` writes a short note,
  `x` or Delete removes one. `}` and `{` jump to the next and previous
  bookmark. The library has a Bookmarks tab across every book (`M` there
  too), searchable by note; a book's details show and edit the notes.
  Notes travel in the sidecar: a note replaces the bookmark with a new
  one and marks the old one removed, so the merge needs no edit times.

- **One-page image comics:** a PNG, JPEG or WebP file opens as a comic of
  one page, from the command line, Open With or the open dialog, with
  guided view, balloons and its own sidecar. In the library, an image
  beside comic files is a one-pager of its own; a folder holding only page
  images (and folders of them) is still one folder book. The Linux
  launcher lists the image types under Open With, and the install keeps
  the image viewer you had as the default.

- **Page thumbnails:** `p` (or the grid button on the status line) opens
  a grid of the book's pages, the current one outlined and bookmarked or
  marked pages flagged; arrows, `hjkl`, `G` with a count, a click or a tap
  pick a page, and `''` goes back. Dragging along the progress bar, or
  hovering over it with the mouse, shows a small picture of the page under
  the pointer before you let go. Thumbnails are made only for the pages
  shown, off the UI thread, and kept on disk beside the covers.

- **Clean-up for old scans (`c`, or Settings → Pages):** yellowed paper
  turns white and faded ink dark again, with levels measured on each
  page's own paper colour, so the inks lose the yellow cast too. Zoomed in,
  or in guided view, a scan with fewer pixels than the screen shows is
  enlarged, at most twice over, and sharpened, in the background, and
  cached. Pages without paper, like painted art,
  only get a gentle contrast stretch. Panel detection still sees the page
  as scanned. Off by default, and kept once turned on.

- **Detector built in:** the trained panel and balloon model is packed
  into the Linux build and the APK, so guided view uses it without
  `make install-model` or `make push-model`. The build takes it from
  `assets/models/` (`make model MODEL=...` puts it there); a model
  installed the old way still wins, for trying another one.

- **Wide scanned margins:** guided view no longer shows a page whole just
  because it was scanned with a wide blank margin. The trained detector
  looks at such a page with the margin cut off, whether or not `t` is on;
  with a 12% margin added to the labelled test pages, 68 of 100 are guided
  right instead of 28. Books are detected again once.

- **Panels for the whole library:** after each library scan, the panels of
  every book are found in the background, so guided view is ready in any
  book as soon as it is opened. Progress shows on the library's status
  line, with a pause button; the pass skips what is done, goes on where it
  stopped after a restart, waits while the reader is busy, and can be
  switched off in Settings. Off by default on Android.

- **M9, polish and ship:** `t` auto-trims the white margins off scanned
  pages, and it and the night filter (`i`) are now remembered across books
  and restarts. Any key can be remapped in
  `~/.config/comicredr/keys.toml` ([docs/keys.toml](docs/keys.toml) has the
  defaults; `make keys` starts one). `/` in the `?` overlay searches it,
  fuzzily or with a `/regex/`. `make tarball` packs the Linux release with
  an `install.sh`. Accessibility: 48 px status-line buttons, pages and the
  overlay labelled for screen readers, notices read out as they appear, and
  the layout holds at double text size.

- **Slanted panels:** guided view dims along a panel's real outline when
  it is not a rectangle (slanted gutters, cut corners), so the
  neighbouring panels' corners no longer stay lit. Pages whose slanted
  panels' boxes overlap are now guided instead of shown whole, and read
  top panel first. Books are detected again once.

- **Android:** the APK builds and has been tested on an Android 14
  emulator. `make keystore`, `make apk`, `make install-apk` and
  `make push-model` build, sign and sideload it; the README has the steps.
  PDFs no longer all fail to open on Android, the back gesture steps out
  of guided view and the book instead of closing the app, and the
  reader's status line has buttons for guided view, balloons and
  bookmarks, and puts the page counter first on a phone. The app has its
  own launcher icon.

## 0.1.0 (2026-09-24)

The first tagged version: a working reader on the Fedora desktop, with
guided view. Android builds exist in the tree but are not tested yet.

- **Library:** point it at your comics folders and it scans them into
  Reading, Series, Books and Folders tabs, with covers, series grouping
  from file names, search and bookmarks.
- **Formats:** CBZ files, PDFs (rendered with PDFium) and plain folders of
  page images. CBR is not supported; the README shows how to convert.
- **Reading:** single page or two-page spreads with cover pairing,
  left-to-right or right-to-left, zoom and pan, a night filter, a
  `page X / N` counter and a progress bar.
- **Guided view (`v`):** steps panel by panel, with `panel X / N` in the
  status line. Panels come from the trained ONNX detector when it is
  installed (`make install-model`) and from classic computer vision behind
  a confidence gate otherwise. Pages the gate rejects show whole.
- **Balloon mode (`b`):** steps through the speech balloons inside each
  panel, zoomed in on each one.
- **Keyboard:** standard keys plus a vi-style layer with counts, marks and
  sequences; `?` shows the whole keymap.
- **Touch:** pinch zoom, pan, edge taps and swipes, on the desktop as well
  as the phone.
- **Resume:** reopening a book returns to the same page, panel, balloon,
  mode and zoom.
- **Linux install:** `make install` puts the app, a GNOME launcher, the
  icon and "Open with" entries for CBZ and PDF under `~/.local`.

Not in this version: per-comic sidecar files (M8).
Panels are cached in the app's own database until the sidecars arrive.
