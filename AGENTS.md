# AGENTS.md

Notes for coding agents and contributors working on ComicRedr. The
[README](README.md) is for people using the app; keep it short and put
build internals, test scripts, detector work and conventions here.
[docs/architecture.md](docs/architecture.md) is the overview with
diagrams (parts, page pipeline, input, detection, the model, data); keep
it in step when the architecture or the model changes.

## Conventions

- **Always update the usage guide** (snonux, 2026-09-26). Every PR that
  adds, changes or removes something a user sees, types or taps updates
  [docs/guide/](docs/guide/README.md) in the same PR; a PR is not ready
  without it. A new feature gets a section in the chapter it belongs to
  (or a new chapter file), with an example, and its heading goes in the
  contents page `docs/guide/README.md`. A changed feature has its text,
  keys and pictures corrected where they are; a removed one is taken out,
  contents line included. Retake the pictures that no longer match with
  `tool/guide_shots.sh [section...]` from the release build (WebP stills,
  small GIFs); if that can't be done in the container, say so in the PR.
  The guide is `docs/guide/`: a contents page and one chapter a file,
  written for people, starting with installing.

- Every PR gets a real end-to-end test (see the `tool/e2e_*.sh` scripts
  below) before it is marked ready. If something can't be tested in a
  cloud container (a real phone, a real touchscreen, GNOME Shell), say so
  plainly in the PR.
- Merge with merge commits, not squash, and keep `main` green
  (`make test`).
- Lints: each package has its own `analysis_options.yaml` on
  `package:lints` with strict casts, inference and raw types, the app the
  same over `flutter_lints`; `make analyze` also fails on unformatted
  Dart. Code is written to 120 columns.
- The README is as lean as it can be (snonux, 2026-09-26): an intro, a
  link to the usage guide near the top, a few highlights, the
  screenshots, a five-step quick start that ends with a link to carry on
  in the guide, and the links to architecture.md, training.md, this file
  and the changelog at the bottom. Nothing else: touch, data, CBR and the
  like are guide chapters. Install steps live in `docs/install-linux.md`
  and `docs/install-android.md` (F-Droid first, via snonux's repo
  github.com/snonux/fdroid, then building the APK); the README's quick
  start and the guide's Installing chapter only point to them. Installing and every feature, with examples and screenshots,
  belong in the guide. Internals go here, and training in
  `docs/training.md`. The `?` overlay and `docs/keys.toml` are generated
  from the keymap and are the key reference.
- README screenshots live in `docs/screenshots/` as WebP, taken from the
  release build. Use only public-domain comics or Pepper&Carrot, and keep
  the credits (David Revoy, CC BY 4.0).
- Test comics are fetched from free sources through the manifests in
  `test/`, never committed. Tag each book with its `style` in the manifest.
- **Every button and dialog has a key** (snonux, task 263). A new
  button on a screen gets a `ReaderIntent` with a default key (reuse the
  intent when the action has one) and names it through `KeyHints.tip`,
  never as fixed text. A new dialog is wrapped in `DialogHotkeys`, its
  buttons are labelled with `Mnemonic` (a letter no other button of the
  dialog has), and one control has `autofocus`: Cancel when something
  would be lost. `test/hotkeys_test.dart` fails otherwise; see "Keys for
  buttons and dialogs" below for the rule and its exceptions.
- `docs/keys.toml` is generated: after changing intents or default keys run
  `dart run packages/reader_input/tool/write_keys_toml.dart` from the repo
  root (`packages/reader_input/test/keys_toml_test.dart` fails otherwise).
- Version bumps touch `pubspec.yaml`, `lib/src/version.dart` and
  `CHANGELOG.md` together (`test/version_test.dart` checks the first two).
- The app points users at sections of the guide's Installing chapter
  (`docs/guide/01-installing.md`) by name: "The CBR files you already
  have" (`lib/src/reader/open_book.dart`) and "The panel detector"
  (`lib/src/library/settings_dialog.dart`). Keep those headings or update
  the strings.

## Releases

A release is a `vX.Y.Z` tag on a commit whose `pubspec.yaml` says
`version: X.Y.Z+N`, with `N` incremented from the current build and higher
than the last published release:

1. Bump `version:` in `pubspec.yaml` and move the `Unreleased` notes in
   `CHANGELOG.md` under the new version.
2. Write `fastlane/metadata/android/en-US/changelogs/N.txt`, a few lines
   (at most 500 characters), and copy it to `1000+N.txt`, `2000+N.txt`
   and `4000+N.txt`. Flutter's split APKs use these ABI version codes,
   which F-Droid reads for *What's new*.
3. Commit, `git tag vX.Y.Z`, `git push && git push origin vX.Y.Z`.

The tag starts `.github/workflows/release.yml`, which builds the armeabi-v7a,
arm64-v8a and x86_64 APKs with the release key and attaches them to the
GitHub release of the tag. The
[F-Droid repository](https://github.com/snonux/fdroid) picks it up with the
store listing in `fastlane/` at that tag. The workflow needs these
repository secrets, taken from `android/key.properties`:

```sh
base64 -w0 ~/.config/comicredr/release.jks | gh secret set ANDROID_KEYSTORE
gh secret set ANDROID_KEY_ALIAS          # comicredr
gh secret set ANDROID_KEYSTORE_PASSWORD  # storePassword
gh secret set ANDROID_KEY_PASSWORD       # keyPassword
```

With an optional `FDROID_DISPATCH_TOKEN` (a fine-grained token with
*Contents: read and write* on snonux/fdroid) the F-Droid repository
refreshes right away instead of within six hours.

## Cloud container setup

- The Linux e2e scripts need
  `apt-get install libgtk-3-dev libsecret-1-dev xvfb xdotool imagemagick sqlite3 openbox
  x11-utils desktop-file-utils wmctrl` first (xprop for e2e_fullscreen,
  update-desktop-database for e2e_images); most also use Python with
  Pillow, e2e_margins OpenCV (`pip install opencv-python-headless`), and
  e2e_smooth_scroll ffmpeg and numpy.
  e2e_m9 installs from `make tarball`, so run that first.
- The first `flutter build` or `flutter run` downloads PDFium once, so it
  needs the network.
- Cloud sessions can push only their own branch: pushing tags and
  creating releases fails with 403.
- Fetching the corpus needs archive.org, huggingface.co and
  peppercarrot.com. digitalcomicmuseum.com and comicbookplus.com refuse
  cloud containers.
- The ONNX Runtime plugin has no x86_64 Android build; `make apk` with
  `APK_ABI` including `android-x64` fetches ONNX Runtime's own x86_64
  library into the gitignored `android/app/src/main/jniLibs/`
  (`MAVEN=https://maven-central.storage-download.googleapis.com/maven2`
  when Maven Central answers 429). The emulator has no KVM there, so a
  page takes about 13 minutes to detect (0.2 s natively); the results
  match Linux.
- On that emulator every PNG fails to decode, in any Flutter app: its
  emulated CPU breaks zlib's checksums (`ZLibCodec` throws, raw deflate
  works). Use JPEG comics there; phones are not affected.
- The same emulator draws nothing but black for a Flutter app on
  Impeller (the default) with `-gpu swiftshader_indirect`: frames are
  made, the screenshot is black. For screenshots, build with
  `<meta-data android:name="io.flutter.embedding.android.EnableImpeller"
  android:value="false"/>` in the manifest's `<application>` locally
  (never commit it). A Pixel Tablet AVD (`avdmanager create avd -d
  pixel_tablet`, 2560x1600, 3 GB) is the 10-inch tablet; `adb shell wm
  size 1200x1920` makes an 8-inch one and `wm size 1280x1600` a half
  screen, since the emulator's split screen (`WMShell splitscreen
  moveToSideStage`) does not start without KVM. `settings put system
  user_rotation 1` turns it upright (its natural side is landscape).

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
  Symlinked comics and folders are followed (`findBooks`, the watcher,
  `FolderDocument`, `isFolderBook`), each real folder once (`firstVisit`
  in comic_formats), so a link back up the tree ends the walk; a dangling
  link is skipped. A linked book's sidecar goes beside the link, and
  deleting it removes the link only (`removePath`).
- Panels are detected in the background for the open book only, guided
  view on or off (`_ensurePanels`, `reader_notifier.dart`): the current
  page, the two ahead and the one behind, then the rest of the book ahead
  of the reader, resting as long as the last page took before each of
  those (a page turn cuts the rest short). Closing the book stops it.
  There is no whole-library pass (removed at snonux's ask, 2026-09-26).
  Results are cached in the app database and the book's sidecar. A confidence gate
  shows the page whole when the panels don't look like a real layout; the
  status line says why. A page is analysed again when the model file
  changes.
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
  With a comic open, `*` and `gc` (`addToCollection`) are about that
  comic and are taken by `HomeScreen._onOpenComic` before the page grid
  or the bookmark list see the command, so they work over both, which
  stay up (t563). `*` goes to `ReaderNotifier._toggleFavourite` (a
  status-line notice, no Undo: `*` again undoes it). `gc` runs
  `_collect`, which asks as the library does and then calls
  `ReaderNotifier.addToCollection` ("Already in X" and nothing written
  when it is: `LibraryStore.addToCollection` returns false and leaves the
  row, the one rule for reader and library). When the comic was closed
  or swapped while the dialog was up nothing is written and `_say` tells
  ("X is no longer open: not added
  to Y", status line or snackbar). The details view (`I`) and the `?`
  overlay are
  left alone: `I` is a modal route with its own keys, and nothing reaches
  the comic behind `?`. No touch button for `gc` in the reader.
- The collection question (`lib/src/library/collection_dialog.dart`) has
  one path for every asker: `askCollection(context, ref, what:, keys:)`,
  used by `gc` in the reader (`_collect`), `gc` and the marks bar's
  Collection in the library (`addBooksToCollection`, bulk_actions.dart)
  and the details pane's and page's button (book_detail.dart). It goes to
  `CollectionAsker` (`collectionAskerProvider`), which makes a
  `CollectionQuestion`: the dialog's `DialogRoute` is pushed in the same
  call, nothing awaited first, so callers must ask before their first
  await. The names offered are read while it shows
  (`LibraryStore.collectionNames()`, every live collection, less
  `collectionsOfAll(keys)`, the ones every asked comic is in; from the
  rows, not `booksProvider`, since neither an open comic nor a
  collection's comics need be in a library folder) and come as
  `CollectionDialog.later`; when that fails the dialog says so in place
  of the chips. Until the dialog's field has the focus (a frame at best,
  about a second for the first dialog of a run) keys still arrive at
  ReaderKeyboard, which asks its `typeAhead` (`HomeScreen._typeAhead` →
  `CollectionAsker.typed`) before looking a key up:
  `CollectionQuestion.typed` puts characters in the field (capitals,
  spaces, repeats), Backspace takes one off, Enter answers, Esc leaves,
  anything else (arrows, Tab, Delete, control characters, a key with
  Ctrl, Alt or Meta) is dropped, so nothing typed after `gc` is a
  command, in the reader or the library. A dead-key or Compose accent is
  lost in that gap: the input method only composes for a focused field.
  Touches need nothing, the Navigator absorbs pointers from the push on.
  Whether a question is open is `CollectionQuestion.open`, the route's
  `isActive`, and nothing else keeps a copy. The asker has no guard
  against a second question while one is up: no input reaches it (keys
  all go to `typed`, also Enter or Space on a focused button, since every
  asker is under ReaderKeyboard; a second tap is absorbed by the
  Navigator); a test holds the second tap and a second `gc`.
  After the answer the library's askers share `collectBooks`
  (bulk_actions.dart; `addBooksToCollection` leaves out comics only on S3
  first, the details' button passes its one book): each comic goes
  through `LibraryStore.addToCollection`, which leaves one already in the
  collection alone and says so (no row rewritten, so `added_at` stays;
  one taken out earlier is put in again). Only the comics really added
  have their sidecars written, and the notice (`collectedNotice`) counts
  those: "2 comics added to X; 1 was already in it", "Already in X" for
  one, "All 3 comics are already in X". When the index fails part of the
  way the comics after that one are not tried, the ones before it stay
  added with their sidecars written, the marks stay (`collectBooks`
  returns false) and `notAddedNotice` counts all three kinds, leaving out
  a zero: "1 comic added to X; 1 was already in it; 1 not added: the
  library could not be updated" (not added = the refused one and those
  never tried), "2 were already in X; 1 not added: …" with none added,
  "Could not add the 3 comics to X: …" when it failed at the first, and
  "Could not add NAME to X: …" for the details' one comic. The error
  itself goes to the log (`debugPrint`), not into the notice.
  What the untouched `added_at` means for sync (a change with t563:
  before, every add wrote the row again with the time now):
  `mergeSidecars` lets the later of `removedAt ?? addedAt` win per
  collection, so a comic taken out on another device after its first add
  here goes out here too when that sidecar arrives, even if `gc` put it
  in that collection here again in between; that changed nothing and is
  no newer add. Taking it out and adding it again here is (a new row
  time), and wins. `*` never adds a favourite twice (on one it takes it
  out), so the Favourites behave as before. The merge rule itself is
  unchanged; `test/collections_history_test.dart` holds both outcomes.
- Keys for buttons and dialogs (task 263, `lib/src/hotkeys.dart`). Two
  rules, by where a button is, since that decides who gets the keys.
  **On a screen** (the library, the reader, and the overlays that are
  part of it: page grid, bookmark list, parts picker, `?`) the keys go to
  ReaderKeyboard, so Tab is `cycleModeForward` and no button can be
  walked to: each button sends a `ReaderIntent` that has a key, and its
  tooltip, or its label where it has one, names that key from the live
  keymap: `KeyHints.tip(context, 'Favourites', ReaderIntent.showFavourites)`
  gives `Favourites (gf)`, the first binding of the intent as
  `Keymap.spoken` writes it (`Ctrl+A`, `Shift+Delete`), and no brackets
  when keys.toml left the intent without a key. `KeyHints` is an
  inherited widget put above the Navigator by `MaterialApp.builder`
  (app.dart), so dialogs read it too; without one (a widget pumped alone
  in a test) the default keys are named. Where a wider label would move
  what a finger or an e2e script aims at (the empty library's buttons,
  the parts picker's, the details' Read and Download), the key is in a
  `Tooltip` around the button instead. Intents added for buttons that had
  no key: `showSettings` (`g,`; app.dart sends it to the library also
  with a comic open, and `LibraryScreenState._settingsOpen` keeps a
  second `g,`, typed before the dialog has the focus, from stacking a
  second dialog), `undo` (`u`), `downloadFromS3` (`gD`), `removeRoot`
  (`gA`), `showScanFailures` (`g!`, a notice when nothing failed), and
  `remove` (`x`) now also takes the selected comic, or with marks the
  marked ones, out of an open collection (`takeOutOfCollection` in
  bulk_actions.dart; a sidecar that can't be written is no failure, as
  for a favourite). The library's own of these are in
  `LibraryScreenState._buttonKeys`, not in `handle`'s switch.
  `gA` and its button in a folder's details go one way,
  `LibraryScreenState._removeRoot` (`FolderDetail.onRemoveRoot`): the
  folder's rows leave the index, nothing on disk is touched, and the
  notice has an Undo, since two keys take a whole folder off the shelves
  unasked. The Undo is `restoreLibraryFolder` (default_folder.dart: the
  folder added again, and `library.defaultFolderRemoved` put back to
  false when this taking out was what set it, which
  `removeLibraryFolder` answers) and then `LibraryScreen.onRescan`
  (HomeScreen's `_rescan`, which also watches the folder again).
  `u` presses the Undo of the notice that
  shows: a SnackBar's action is out of the keyboard's reach, so the
  notices with an Undo go through `UndoNotice` (`undoNoticeProvider`,
  `lib/src/undo_notice.dart`), which keeps what the button does until
  the notice has gone and runs it once, by button or by key (also the
  key and then the button of a notice still on its way out). The rule:
  whenever such a notice is visible `u` runs it, on any screen, and with
  none it does nothing and says nothing. So `u` is taken by
  `HomeScreen._buttonKey`, before the help, the reader or the library
  see the command: the notice of something done in the library is still
  up over a comic opened straight after it, and `u` works with the help
  up. What the Undo throws is caught and said in a notice
  (`UndoNotice.show(failed:)`), since nobody awaits a button or a key.
  Notices, one rule (second and third review of t263): every notice of
  the app is shown through `showNotice(messenger, text)` or
  `UndoNotice.show`, both in `lib/src/undo_notice.dart`, and both end in
  `_post`. A notice is routine (something done, a hint, an Undo offer)
  or must be read (`mustRead: true`: a failure, or a warning about what
  was done). A routine one takes the place of a routine one that is up,
  at once (`clearSnackBars` and `removeCurrentSnackBar`, no slide out),
  so routine notices never queue: before, a notice shown with a plain
  `showSnackBar` waited unseen behind an Undo notice, and `u` could run
  the undo of a notice not yet on screen, which then showed a dead
  button. One that must be read also takes a routine one's place at
  once, and then stays its whole time: whatever comes meanwhile waits
  behind it (`_Line.waiting`, kept per messenger in an Expando, not the
  messenger's own queue), those that must be read all in the order they
  came, while a routine one waiting gives way to whatever comes after
  it, so at most one routine notice follows. Else "Downloaded B" took
  "Could not download A" away a moment after it came up. A burst of
  them holds the screen only so long (fourth review; thirty refused
  downloads held it for two minutes, an Undo offer behind them dropped
  unseen), by three things. `_post` does not queue a must-read notice
  whose text is the one showing or one waiting (`_saidAlready`; never
  one with an Undo, whose button is its own), and does so before
  anything gives way to it, so a routine or Undo notice waiting behind
  repeats of one failure stays. At most `_mostWaiting` (2) must-read
  notices wait: when one more comes, the last waiting one becomes
  "… and N more notices" (`_Notice.more`), N counting it and all after
  it, so a burst is the notice showing, the first waiting and that
  count, three notices' time; what is lost is the text of the third
  and later distinct notices of a burst (and an Undo the folded one
  offered, as for any notice that gives way waiting). A routine notice
  after the burst still waits as the one last in line. And the sources
  say a thing once: marked downloads go through `S3Sync.downloadAll`,
  which stops at what stops them all (no library folder: "Add a library
  folder first" once; the bucket out of reach: "S3 is out of reach: 5
  comics can be downloaded when it is back", the comics left counted,
  one alone named) and goes on after a refusal of one comic ("Could not
  download X: …"); a drain says a refusal ("S3: …") once per `drain`
  for each different message, not once a waiting comic. An Undo notice
  that waits has no key until it shows (`UndoNotice.show` sets what `u`
  runs in `onShown`), and one that gave way while waiting never gets
  it; `UndoNotice.show(mustRead: true)` is for an Undo whose text also
  tells of a failure (`takeOutOfCollection` part of the way). Which
  are which: `mustRead` is passed where the text says "could not", a
  sidecar that stayed, a reset the file beside the comic may undo, the
  start-up warning about keys.toml, everything Import settings says,
  and S3 Save when no keyring answered. The sync's notices are
  `S3Notice` records (`text`, `failure`; `S3Sync._say` and `_fail`), and
  HomeScreen's listener passes `failure` on: out of reach, a refusal, a
  failed download and "Add a library folder first" are failures,
  "Uploaded", "Downloaded", "… was on S3 already", "Removed … from S3"
  and "S3 is back" routine (`test/s3_sync_test.dart`, "what the sync
  says", provokes every one of them on a bucket that can refuse and
  holds which is which). A new notice: decide which it is. A notice with an Undo goes
  by itself after
  `undoNoticeTime` (10 s; `persist: false`, since in this Flutter a
  SnackBar with an action otherwise stays until hidden), a plain one
  after `noticeTime` (4 s) unless its caller says; once it has gone,
  however, `u` is nothing again. `test/hotkeys_test.dart` fails on a
  `showSnackBar` anywhere else in lib/.
  `x` in an open collection (`takeOutOfCollection`): with marks of
  which none is in it, a notice says so (`notInCollectionNotice`); when
  the index fails part of the way the comics taken out before still get
  their notice with an Undo, which counts the ones not taken out
  (`takenOutNotice`), and the marks stay.
  Controls left without a key of their own, each a shortcut to something
  the keys reach in two steps. The walk in `test/hotkeys_test.dart`
  looks at every button, chip, ListTile, switch and bare
  InkWell/GestureDetector with an `onTap` on the screens it visits, under
  the default keys and under a keymap with none of them (so a tooltip
  with a key written into its text fails), and a control that names no
  key must be in its `noKey` list, by the name of the nearest widget key
  at or above it; an entry the walk no longer meets fails too. The
  exceptions: the breadcrumb's folder names
  (`Backspace`, a folder at a time; their tooltips say so), **Read** /
  **Continue** in a series' or a folder's details (`readNext`,
  `continueInFolder`: Enter, then Enter on the comic), the x on a part
  of the filter line and its Clear filter (`F`, then the chips and
  Alt+C; the tooltips name `F`), Note and Remove on a bookmark and the x
  of a collection chip in a book's details (tooltips name `e` and `x`
  and where they work), the parts picker's choice of split (the part's
  own key picks it), tabs (Tab, Shift+Tab), and rows and covers (arrows
  and Enter: covers `b:` `f:` `s:`, the page grid's `pageTile-`, the
  Bookmarks tab's `bookmarkItem-`, the reader's list's `bookmarkRow-`,
  History's `history-`), the comics listed in a series' details
  (`seriesBook-`: Enter shows the books, then the arrows and Enter) and
  the bookmarks listed in a comic's details (`detailBookmark-`: the
  Bookmarks tab or `M`, then the arrows and Enter), the parts picker's
  backdrop (`partsPicker`: Esc). A folder's details have no rows.
  Pointer-only by nature: the progress bar, the bookmark
  ribbon (`M`), the text field's clear button (Esc). Help texts that
  spell keys in a sentence (Settings' subtitles, the empty library's
  paragraph, empty tabs) are still fixed text.
  **In a dialog** (a route, which has the focus, so ReaderKeyboard sees
  none of its keys and nothing typed acts on what is behind) Esc, Enter,
  Tab, the arrows and Space are Flutter's. `DialogHotkeys` around the
  dialog adds three things. (1) Alt and a letter presses the button
  whose `Mnemonic` label has that letter (the first of the text unless
  `letter:` names another; the label finds its button by walking up to
  the nearest `ButtonStyleButton` and calls its `onPressed`, so a
  disabled button does nothing and `.icon` buttons work). Alt, not the
  bare letter, so a letter typed into a dialog's field is text; Ctrl+Alt
  and AltGr are not Alt. ReaderKeyboard in turn drops a key that types a
  character (a letter, a digit, a sign, Space) when Alt is held: no
  binding has Alt, and an Alt+C too many after a dialog closed must not
  be `c` on the comic. Keys that type nothing (arrows, Enter, Home, the
  F-keys) act with Alt as without, as before the task: they are no
  dialog's letter. Two labels
  with one letter trip an assert when
  the key is pressed. The letters are underlined on Linux, macOS and
  Windows; on Android and iOS only while Alt is held
  (`DialogHotkeys.debugTouchFirst` for tests), so touch sees no change.
  (2) Tab order is the order the controls are written in
  (`_WrittenOrderPolicy`, a walk of the dialog's widgets): Flutter's
  default orders by position on screen, which in Settings, whose content
  scrolls, changed as Tab scrolled it, so Tab went round eight controls
  and never reached the switches or sliders; its
  `WidgetOrderTraversalPolicy` is the order the controls were made in,
  which put the collection question's chips (read from the index, so
  made after the buttons) behind Cancel and Add. (3) The letters are
  taken in one place, an early key handler of the `FocusManager`
  (`addEarlyKeyEventHandler`), for the dialog whose route is on top
  (`isCurrent`: Settings under a question it asked has no letters), not
  by a node of the focus tree: they work before anything in the dialog
  has the focus, and the wrapper holds no focus node of its own (one
  that took the focus when nothing else had it kept the S3 settings'
  first field, which shows only once the settings are read, from getting
  its autofocus). A dialog still autofocuses a control, for Enter. It
  must be an early handler and not one of `HardwareKeyboard`: Flutter
  gives a key to the hardware handlers and to the focus tree both,
  whatever the first answer, while what an early handler takes the
  focus tree never sees. (With a `HardwareKeyboard` handler, Alt+R in
  the comic's details was taken by the button's label and by a
  `CallbackShortcuts` of the view on one press: two `Navigator.pop`s,
  the second of the app's own route, a dead window.) One press of a key
  presses once (`_taken`, the event last acted on). No dialog has an Alt
  shortcut of its own; the source scan fails on `alt: true` in lib/. A
  button that is not always built names its key with `DialogKey(letter:,
  onPressed:, child:)` around something that is, and is labelled
  `Mnemonic.shown`, which only underlines: Redo panels in `ComicDetails`
  (Alt+P, a row of a lazily built list; the same letter as Redo panels
  in the reset question, where Alt+R is Reset everything, so one chord
  is never a mild thing here and a destructive one there), and
  Settings' two cover size buttons, which have a picture and no label
  (Alt+M smaller, Alt+B bigger, named in their tooltips).
  `ComicDetails` closes through `_leave`, once, whatever asks.
  Other dialogs' own shortcuts were looked at for the same double
  dispatch: the move dialog's `CallbackShortcuts` has the arrows, Page
  keys and Ctrl+N, none of them a letter of `DialogHotkeys` (which lets
  Ctrl+Alt and Ctrl pass), and the details' has only plain keys; Enter
  in a field is the field's `onSubmitted` alone and Esc is Flutter's
  dismiss, one pop each. The dialog walk in the test counts routes
  popped with a `NavigatorObserver` (`ComicRedrApp.navigatorObservers`):
  one for Esc and one for the Alt+letter of Cancel, Close or Done in
  every dialog it opens.
  The ring around the focused control is `withFocusRing` on both themes:
  a 2 px `side` for the focused state of the button, chip and
  segmented-button themes and a stronger `focusColor`; Flutter reports
  the focused state only in `FocusHighlightMode.traditional`, i.e. while
  keys or a mouse are in use.
  Not done, for follow-up tasks: Settings' rows have no letters of their
  own (Tab and Space; only its buttons have); help sentences that spell
  keys (Settings' subtitles, the empty library's paragraph, empty tabs)
  are fixed text, not read from the keymap; `tool/e2e_touch_zones.sh`
  does not parse ImageMagick 7's output; the collection chips of the
  collection question and the pages of the details list are reached by
  Tab only; the dialogs only Android shows (storage access, the folder
  paths) and the ones that need another device or a bucket (position
  offer, import confirmation, S3 settings and its Turn off, Remove from
  S3, the move clash, failures) are wrapped and lettered, but the
  keyboard walk in `test/hotkeys_test.dart` does not open them (its scan
  of the sources covers their wrapping and labels, and fails on anything
  else that opens over the screen, a sheet, a menu, a dropdown, a route
  made by hand, unless it is in `knownOverlays` with its reason); the
  system's file pickers are GTK's own.
  `tool/guide_shots.sh`, `tool/e2e_hotkeys.sh`, `e2e_favourites`,
  `e2e_folder_filter` and `e2e_delete` start the app with
  the XDG data, config and cache folders unset, `GDK_BACKEND=x11` and
  `DBUS_SESSION_BUS_ADDRESS` set to a socket that is not there: with the
  session bus in reach the S3 dialog reads the real keyring of whoever
  runs them (the guide's picture said "A secret key is saved in the
  keyring"), and Enter in an S3 field saves. Unsetting the address is
  not enough on a desktop: D-Bus then looks at `$XDG_RUNTIME_DIR/bus`,
  the real session's (seen 2026-10-07: the picture still said "saved").
  The S3 e2e scripts (`e2e_s3_settings`, `e2e_s3_reader`,
  `e2e_s3_android`), which save a test secret, export the same dead
  address for the whole script and start the app with the XDG folders
  unset and `GDK_BACKEND=x11` as well; `e2e_reset` and `e2e_m8_library`
  start the app the same way (third review). The other older e2e
  scripts still set only HOME: export the three by hand on a desktop. A script that
  starts the app right after Xvfb waits for the display first
  (`xdotool getdisplaygeometry`; `e2e_delete`, `e2e_reset` and
  `e2e_m8_library` died with "cannot open display" without it).
- Continue (`C`, the library header's play button, widget key `continue`):
  `RecentBooks` (`lib/src/reader/recent_books.dart`) keeps the last five
  comics opened, path, content key and title, newest first, in the
  setting `reader.recent`; `ReaderNotifier.open` puts each one first. It
  is per install (paths), so not in `SettingsStore.backedUp`.
  `HomeScreen._continueReading` opens the newest that is not the open
  comic; the position comes back as on any open. A missing path is looked
  up by content key in the library (a moved comic); failing that, a
  notice and the entry is dropped.
  At start (t873, `HomeScreen._continueAtStart`, from `_start` before the
  scan) the same opens the comic read last, unless the setting
  `library.continueAtStart` (Settings → Library, in `backedUp`) is false,
  or the command line named a comic or folder (that opens instead) or an
  `--add-root`: a start that adds a library folder stays in the library,
  which is what every e2e script that passes `--add-root` expects. With
  nothing read it says nothing. The e2e scripts that start the app with no
  arguments after a comic was read get that comic.
- Touch: `ReaderTouch` looks every gesture up in a `TouchMap`
  (`reader_input` touch_map.dart): taps, double-taps and long presses on a
  3x3 grid (30% side columns, rows in thirds), four swipes and a
  two-finger tap, each mapped to a ReaderIntent. The map is the preset
  picked in Settings (`touch.preset`) with the `[touch]` lines of
  keys.toml over it. A tap only waits for a possible second tap in a zone
  that has a double-tap action, so edge taps turn at once. Pinch zoom and
  panning stay with the InteractiveViewer and can't be remapped.
  Nothing in it is per platform: Flutter's Linux engine turns GTK touch
  events into touch pointers (`FlTouchManager`; the view selects
  `GDK_TOUCH_MASK`, which `tool/touch_inject.c` reports), so a Linux
  touchscreen gets every gesture. Android's back gesture is the one thing
  Linux lacked; there the status line starts with a back arrow sending
  `ReaderIntent.back` (`_StatusLine.showBack`).
- Page thumbnails (the `p` grid and the progress bar's preview) come from
  `Thumbnails` in `lib/src/reader/thumbnails.dart`: made on demand through
  the book's own document (so PDFs use the shared PDFium isolate), scaled
  by Flutter's decoder, JPEG-encoded on a short isolate and kept in
  `<cache>/covers/pages/<content key>/<page>.jpg`. Newest request first,
  two at a time; tiles evict their images when they scroll away.
- Cover size (`+` `-` `=`, Ctrl+wheel, a pinch, two buttons in Settings;
  snonux, task 063): the reader's `zoomIn`/`zoomOut`/`zoomReset`
  intents, which `LibraryScreenState.handle` takes on a tab of covers.
  They, the pinch and the buttons all end in `_setCoverColumns`, which
  does nothing and saves nothing unless the cover grid is on screen
  (`_coversShown`: the `GridZoomArea`'s GlobalKey has a state, so not on
  the History and Bookmarks lists, an empty tab, or a phone-wide window
  with a cover's or folder's details page up). `GridZoom`
  (`lib/src/grid_zoom.dart`) is the arithmetic the page grid (`p`) and
  the cover grids share: a step is one column, what is kept is the tile
  width that gives (`tileWidth`), and `columns` brings a kept width back
  to a column count within `fewest`..`most`. It never throws, whatever
  the width or target (NaN, zero and below give the most columns,
  infinity the fewest). The page grid is
  `GridZoom.pages` (gap 8, smallest 56, down to one page a row), the
  covers `GridZoom.covers` (gap 12, 72 to 480 px), which the tests use
  too; unzoomed, the covers
  aim for 160 px and never fewer than two a row
  (`LibraryScreenState.usualCoverColumns`), counted with
  `GridZoom.fitting`, which has no rounding allowance: exactly the
  columns of before the task at every width (`columns` adds 0.01 for a
  kept size, which at 160 px showed three covers for two in a grid 526.3
  to 528 px wide; test/grid_zoom_test.dart compares both grids' usual
  columns with the old expressions for every half pixel from 200 to
  4000). The page grid's usual columns (`PageGridState.usualColumns`)
  always had the allowance and keep it. A step that lands on the usual
  columns for the current width is the usual size (`_setCoverColumns`
  clears `_coverTarget` and unsets the setting, as `=` does), so `+`
  then `-` changes nothing: not the decode width, not the page files
  made, not the Usual size button. A stored `library.coverSize` of
  exactly 160 (only a hand-written file has one) is read as the usual
  size and the setting left as it is; any other stored width is a size
  set by hand, also where it happens to give the usual columns, since it
  gives others once the window changes. The page grid has no such rule:
  its pictures do not depend on being zoomed.
  `GridZoomArea` (same file) wraps either grid in a `Listener`: Ctrl and
  the wheel, a touchpad pinch (pan-zoom events) and two touch pointers
  (a step per quarter the fingers spread or close, `pinchSteps`) call
  `onColumns`, which answers with the columns the grid then has (clamped),
  and the grid is built with the physics it hands over
  (`NeverScrollableScrollPhysics` while two or more fingers are down or
  Ctrl is held). The pinch is between the first two fingers down and
  starts again (`_rebase`: spread and columns as they are now) whenever a
  finger comes or goes, so a third finger taking over from one that
  lifted does not jump. It asks the grid only when the fingers reach
  another step (`_pinchSteps`), and starts again from the grid's columns
  when they changed from outside while it is under way (`_restartPinch`
  from `didUpdateWidget`, when `widget.columns` is not what the area
  last knew: a key, a Settings button, a resize; a touchpad pinch then
  counts its scale from `_padFrom`). So a `+` typed with two fingers down
  keeps its step, before the next frame as after it, and a resize is not
  answered with the old width's columns. One gap is left: a pinch that
  reaches a new step in the very frame of a key's step, before the area
  is built again, still asks from the columns of before the key.
  The columns it starts again from, and the ones a
  wheel notch or a new touchpad pinch counts from, are `_columns`: the
  grid's last answer until the area is built again, since several pointer
  events can come within one frame, when `widget.columns` is still the
  count of before the step (test/grid_zoom_test.dart does a step, a
  finger down and a move without a pump; the page grid's `_columnsNow`
  is the same for its own compare; test/cover_zoom_test.dart and
  test/page_grid_test.dart do two wheel notches, then a notch and a
  pinch, without a pump on the real grids, which is what proves the
  answers their `onColumns` give). Every pointer callback checks `mounted`, since a
  touch keeps reporting to a grid that a tab change took away. Its
  `pinched` stays true from the second finger down until the
  next touch starts; while it is, the cover grid drops taps and long
  presses and the page grid taps, so a finger resting during a pinch
  opens nothing. The covers' width
  is `_coverTarget`, one for every tab, saved as `library.coverSize`,
  the page grid's as `grid.zoom`: the width in full
  (`SettingsStore.sizeText`, the double's own text; a tenth of a pixel
  could give a column fewer back from 16 columns on in the page grid and
  19 in the covers), unset for the default. Both are in `SettingsStore.backedUp` and
  `SettingsStore.sizes`; `SettingsStore.parseSize` reads one, null unless
  it is a finite number above zero, which is what a settings file must
  give (`SettingsFile._fits`) and what both grids take up at start (a
  `NaN` put there by hand is the default size). `reloadSettings` reloads
  it after an import. After a zoom
  `_showAgain` reveals the selected cover if it was on screen, else puts
  the row that was along the top back there. Settings → Library → Cover
  size (`_CoverSizePicker` in `settings_dialog.dart`) drives the library
  through the `CoverSizer` interface `LibraryScreenState` implements
  (`showSettings(covers: this)`): two buttons and Usual size, off at the
  limits and while no cover grid is behind the dialog. `CoverSizer` is a
  `Listenable` and the line a `ListenableBuilder` on it: the library
  notes what the line would say after every build and layout
  (`_tellSizer`, a post-frame callback setting `_sizerState`), so it
  follows a resize, the first comics of a scan and the buttons alike.
  The line is above the buttons, which are in a `Wrap`: it fits 320 dp
  and 1.5x letters (tested). It sits between
  Guided view and Sidecars, so what the e2e scripts click above it,
  counted from the dialog's top, has not moved; the ones that click from
  its bottom (e2e_s3_settings, e2e_settings_backup) scroll 30 wheel
  notches to get there, since 20 no longer reach the end.
  Pictures: cover files are 512 px wide (the scanner makes them), so a
  cover is sharp up to 512 device pixels and scaled up beyond (480 px
  covers at 3x are 1440); the range is not cut down for that, and the
  guide says so. What a tile decodes is `coverPictureSizes`
  (`cover_card.dart`). At the usual size (`_coverTarget` null, which a
  step back to the usual columns restores) it is what
  it was before covers could be sized, on every screen: covers 400 px
  (`usualCoverDecodeWidth`), shuffled pages the 256 px file. So a phone's
  usual covers, some 490 device pixels wide at 3x, are decoded at 400 and
  not as sharp as the file allows; that was chosen (2026-10-07) so that
  memory (0.96 MB a cover, not 1.57) and the page files made do not
  change for whoever never sizes the covers. Sized by hand, a cover
  decodes at the first of 128, 256, 400, 512 px (`coverDecodeWidths`)
  that covers the tile's device pixels (`coverDecodeWidth`), so small
  covers are small in memory (about 200 of 72 px in a 1920 px window:
  20 MB, where 400 px each would be 190 MB against the image cache's
  100 MB), and a step that stays in a bucket reuses the decoded
  pictures. The other covers do not follow the grid: the details pane
  and page decode at 512, the bookmark and history rows at 96. A shuffled page's file is
  256 or 512 px (`ShufflePages.sizeFor`) and is decoded no wider than
  the cover would be (`ShuffledPage.decodeWidth`).
- Shuffle (`S` on the Folders tab, `gs` picks again; setting
  `library.shuffle`): each book tile shows page `shufflePage(key, pages,
  seed)` instead of its cover, never page 1, from a seed made anew when
  shuffle turns on, a folder is entered or `gs`, so scrolling keeps the
  picks. `ShufflePages` (`lib/src/library/shuffle.dart`) makes them into
  the page grid's thumbnail files (`<cache>/covers/pages/<key>/<n>.jpg`,
  256 px; `w512/<n>.jpg`, 512 px, for tiles more than 332.8 device pixels
  wide in a grid sized by hand, never at the usual cover size
  and never the grid's 1024) for tiles on screen only, newest first,
  two at a time; each opens
  the book through `BackgroundDocument` and closes it straight after. The
  cover shows until the page is ready, and the 256 px page until a 512 px
  one is. On a phone-wide header the
  reshuffle button is left out; `gs` or `S` twice picks again.
- The Folders tab's filter (`F`, `ReaderIntent.filterFolders`;
  `FolderFilter` in `lib/src/library/folder_filter.dart`, its window in
  `folder_filter_dialog.dart`): a set of `LibraryBook.format`s, a
  `SizeRange`, a `DateRange`, a `CompletedFilter` (any, only, hide;
  by `LibraryBook.completed`, task 273) and a `PageRange` (by
  `LibraryBook.pageCount`, task 363; a count of 0, a comic on S3 whose
  manifest said none, passes only Any length), applied to the books before
  `LibraryFolder.roots`/`children` build the tab, so folder counts are of
  what passes and folders with none go. Size and date are the first
  file's `files.size` and `files.mtime` (a folder book: its pages' total
  and newest), read in `_booksSql` into `LibraryBook.size`/`modified`; a
  comic on S3 only uses the upload's. Saved as JSON in
  `library.folderFilter` (in `SettingsStore.backedUp`, unset when
  off). It has its own line under the header (`_filterBar`), since the
  header has no room left beside a breadcrumb on a tablet or phone.
  A part more is a field whose default lets
  everything through and a line each in `isActive`, `accepts`,
  `copyWith`, `encode`, `decode`, `==` and `hashCode`, its chips at the
  end of the dialog (the e2e scripts count Tab stops from the first
  chip) and a part on the filter line. `decode` reads a missing or
  unknown part as its default and `encode` leaves `completed` and
  `pages` out at their defaults, so a filter saved before the part existed
  reads, and is written, as it was. "Page size" in task 363 was read as
  the page count; the pages' pixel size is not filtered on.
- The Folders tab's sort (snonux, 2026-10-09; `gS` `sortFolders`, `go`
  `nextSortOrder`, `gO` `reverseSort`; `FolderSort` in
  `lib/src/library/folder_sort.dart`, its window in
  `folder_sort_dialog.dart`): a `SortOrder` (name, added, last read,
  modified, size, pages, series, year) and `reversed`. Applied in
  `_itemsFor` after the filter, to the books (`FolderSort.books`) and to
  the folders (`FolderSort.folders`: each by its first book in the
  order; by name they keep the order `LibraryFolder` gives, which for
  library folders is the order they were added). Name order is
  `LibraryFolder.fileOrder`, the tab's order before there was a sort.
  The value orders put the larger value first unless reversed; a book
  without the value (`readAt` null, no `year`, a page count of 0) goes
  last either way, ties by file name. Saved as `library.folderSort`
  (`size`, `size:reversed`; unset for name A to Z; in
  `SettingsStore.backedUp`, so e2e_settings_backup's export holds 16
  settings), anything unknown read as the usual order. The button sits
  at the right end of the filter line (`_sortButton`, order only below
  600 dp), so the filter's parts did not move. In the window each order's
  chip has a `Mnemonic` with `onPressed` (Alt+N, A, L, M, S, P, E, Y),
  Reverse Alt+R, Done Alt+D; `go` and `gO` say the new order in a
  notice. Only the Folders tab is sorted; the other tabs keep their
  own orders.
- Completed comics (snonux, task 273; `gC`, `ReaderIntent.toggleCompleted`).
  Two facts make it up. `LibraryBook.finished` is the old one, a column
  of `progress`: this device's saved page is the last. The mark is new:
  a row of `overrides` with the field `completed` (`completedField`,
  `completedEdit`, `completedMark` in `lib/src/data/meta_edits.dart`),
  its value a `MetaEdit` as for a metadata edit: `"1"` completed, `"0"`
  marked not completed, `fromFile` for no say (the undo of a first
  mark). `LibraryBook.completed` is `completedMark ?? finished`, so
  comics left on their last page before the mark existed count, and a
  mark either way wins over the page. The cover's green check
  (`completedBadge`), the read counts of series and folders,
  `LibrarySeries.next`, the Reading tab's order and `inProgress` go by
  `completed`. No table and no schema change: an overrides row is keyed
  by content key and dated, `mergeEdits` lets the later one win when
  sidecars meet (so taking the mark off travels), `SettingsFile` exports
  and imports every overrides row by the same rule, S3 carries the
  sidecar, and Reset everything clears the overrides (Redo panels keeps
  them). It is no `MetaField`: `activeEdits` skips it, so it is not in
  the edit form and an older version reading the sidecar ignores it.
  Writing: `LibraryStore.setCompleted(key, true | false | null)`;
  reading one comic's mark: `completedMarkOf` (there is no
  `isCompleted`: the reader's rule goes by the page on screen, the
  library's by the saved row, and a store method by the debounced row
  would be neither).
  In the library `toggleCompleted` (bulk_actions.dart) is the one path
  for `gC` on a cover or with marks (`_buttonKeys`), **Completed** in
  the marks bar and the tick in the details
  (`BookDetail._completedButton`): all completed unless every one is,
  then all not completed; only those that change are written, and the
  notice's Undo (`UndoNotice`, both ways) gives each back the mark it
  had, none included. Comics only on S3 are left out (no sidecar here
  for the mark to travel in) and said: `completedNotice` ends "; 2 are
  only on S3", and when they are all there is, `onlyOnS3Notice` ("Only
  on S3: download it first", "All 2 comics are only on S3: download them
  first") and nothing goes ahead; `gC` therefore passes a selected cover
  that is only on S3 on, where `_markedOrSelected` would drop it. When
  the index fails part of the way it is as `takeOutOfCollection` has it:
  the comics marked before keep the mark, their sidecars are written,
  the notice names them with their Undo and counts the rest ("Akira
  marked as completed; 2 not marked: the library could not be updated"),
  the marks stay (false); refused at the first, "Could not mark 2 comics
  as completed: …" names the comics whose mark was to change, not every
  comic asked for.
  Selection (first review): on the Folders tab under **Not completed**
  or **Completed only** a comic whose mark changes leaves the tab. The
  cover next to it then has the selection
  (`LibraryScreenState._neighbourUnderFilter`, called from `build` when
  the selected cover is gone, its books still exist and the filter's
  completed part now rejects one): of the covers shown before, the first
  after the last that left, else the nearest before, which is delete's
  rule (`_deleteMarked`). It is in `build` and not in the key's handler
  so that every cause has it: `gC`, the marks bar, the tick in the
  details, and the reader marking the comic at its last page while the
  library waits offstage under it. A change of the filter itself never
  gets there: `setFilter` drops the selection, as for the other parts,
  since a comic the new filter hides was not acted on. The Undo
  brings the comic back and leaves the selection, as the Undo of a
  favourite taken out does.
  In the reader `gC` is taken by `HomeScreen._onOpenComic`
  like `*`, so it works over the page grid and the bookmark list, and
  goes to `ReaderNotifier._toggleCompleted` (a status-line notice, no
  Undo: `gC` again), which goes by `completedMarkOf(key) ?? _onLastPage`,
  so on the last page of an unmarked comic the first `gC` says not
  completed. The reader also marks by itself, and only when reading on
  arrives at the end (snonux, first review: "peeking at the end must not
  mark"): `ReaderNotifier.handle` wraps `_dispatch` and, when the
  command was a step onward (`_readsOn`: `nextStep`/`scrollRight`, which
  right to left are `prevStep`/`scrollLeft`, and `nextPage`; taps and
  swipes are these intents) and the last page was not on screen before
  and is after (`_onLastPage`: the last page of the unit, so the last
  pair in two-page mode; in guided view and page parts the step that
  turns the page), calls `_completeAtEnd`. A count makes no difference:
  `3l` or `5` PageDown is the same step several times over
  (`ReaderCommand.times`) and marks when it lands on the last page.
  Nothing else does: `G`, `G` with a page number (`G12`), `''`, a mark,
  `}` `{`, `jumpTo` (page grid, progress bar), `jumpToBookmark`,
  `acceptOffer` (another device's place) and `open` never mark, and a
  step on the last page that goes nowhere is no arrival. Nor does a
  change of mode: on the page before the last, `d` (two pages) brings the
  last page on screen beside it and marks nothing, which is meant, since
  no step onward was taken; the next step back and onward again does.
  `_completeAtEnd` leaves a comic already marked completed
  alone, row and time (a rewritten time would beat another device's
  later "not completed" in a merge), and marks one that was marked not
  completed again: read to the end once more, it is completed once more.
  So a mark taken off on the last page stays off until the page is left
  and stepped onto again. A one-page comic is on its last page from the
  start: no step arrives there and the reader never marks it, but it
  counts as completed from its first open all the same, by the fallback
  (`finished` is true for it as soon as a position is saved); `gC`
  marks it not completed, which stays. The same fallback counts a comic
  jumped to the end of and left there as completed until it is left on
  another page: that is kept (comics finished before the mark existed
  need it). The notice "Last page: marked as completed" shows only when
  the mark was really written and the status line had nothing else to
  say. Why write a mark at all when `finished` says the same: `finished`
  is gone when the comic is read again from page 1, and positions are
  per device, so another device would never hear of it. A comic marked
  completed part-way is not `inProgress`: no progress line on the cover,
  Read again in the details, out of `LibrarySeries.next`, last on the
  Reading tab; it still opens where it was left. `ComicDetails` (`I`)
  has a Completed row saying which of the two decided. A settings import
  counts the mark's rows apart from the metadata edits
  (`SettingsFile.metaEditCount`, `completedMarkCount`: "1 edit and 30
  completed marks" in `importNotice`, both in the question before it).
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
- A page guided view shows whole (no panels that pass the gate,
  `ReaderState.onWholePage`) turns the Scaffold background `heldColour`
  (#3A0D16, app.dart) as soon as it shows, until it is left (snonux,
  2026-09-26). A step onward within `ReaderState.pauseWindow` of that
  moment (`guided.pauseSeconds`, 2 s by default, Settings offers 1, 2, 3,
  5 and 10; snonux 2026-09-27)
  stays, sets `ReaderState.held` and bumps `cue`, which plays ReaderView's
  zoom pulse (none with reduced motion; the status line says to press
  again, always then, else the first three times); the next step turns,
  however soon. A step after it turns at once. The moment is
  `_wholeSince`, set by a `listenSelf` whenever `onWholePage` turns true
  or the page changes, so a page whose panels arrive late, turning guided
  view on or `W` on start it again. Tests set the notifier's `clock`.
  Mirrored going back. A page arrived on from the other side and a count
  (`3l`) are not held (`_pauseOnWhole` in `reader_notifier.dart`). `W` or
  Settings turns it off (`guided.pauseWhole`); there is no cue choice any
  more (`gw` and `guided.pauseCue` are gone).
- Parts of a page (`H1` `H2`, `B1`-`B3`, `L1`-`L4` strips, `Q1`-`Q4`, `lib/src/reader/region.dart`):
  `ReaderState.region` is the split, the part and the page of the unit it
  is on. ReaderView frames it with guided view's camera and dim, in guided
  view or out of it (`_aimCamera`). A part key also sets
  `ReaderState.parts`, the split every step (`→` `←`, `l` `h`, taps) then
  goes through page by page (`_stepParts`): the parts in reading order,
  across a spread's other page, the page (or spread) whole again on its
  far side (region cleared, panel `pageEnd`; snonux 2026-09-29), then the
  next page whole on its near side (`_turnInParts`, panel `pageStart`),
  then its first part; back mirrors it. In guided view a page
  with stops ends the parts (at the turn, or on the next step when its
  panels came late), so guided view goes on. Arrows never pan in parts
  (`_panSideways`). Esc, `00`, the same key, a jump (`_goTo` clears both) or a
  mode switch end it; `11` clears the region and keeps `parts` (whole page
  in the split).
  By touch (`gp`, `ReaderIntent.pickPart`; a two-finger tap in every
  preset, and `partsButton` on the status line from 600 dp):
  `PartsPicker` (`lib/src/reader/parts_picker.dart`), opened from
  `HomeScreen._onCommand`, draws the page's 512 px thumbnail (turned with
  the comic, not trimmed) cut into the split's parts as seen and sends the
  part's own intent (`regionIntent`); any other command closes it and
  goes on, Esc or back only closes it.
  The digit pairs (first digit = how many parts: `11` whole, `21`/`22`
  halves, `31`-`33` thirds, `41`-`44` strips, `51`-`54` quarters; `00`
  leaves) are ordinary bindings too: `KeySequenceResolver`
  treats a count that spells a digit-only binding, each digit within
  `pairWindow` (500 ms) of the one before, as that binding at once (only a
  longer digit binding waits `pairSettle`). Page jumps moved behind the
  key (snonux, 2026-10-01, Helix style): a one-character key of an intent
  in `KeySequenceResolver.takesNumber` (`G`) collects digits after it,
  ended by Enter, a `pairWindow` pause or any other key (handed back by
  `takeQueued`, which ReaderKeyboard dispatches after it). ReaderKeyboard
  arms a timer for the resolver's `deadline` and calls `expire`. A count
  before a key (`3l`) still works when it is not one of the pairs.
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
- Key pans glide (`_pan` in `reader_view.dart`): `j` `k` `↓` `↑` and,
  on a page zoomed in outside guided view and page parts, `←` `→`
  (`ReaderIntent.scrollLeft`/`scrollRight`; app.dart turns them into
  `prevStep`/`nextStep` anywhere else, or when the view can't move that
  way). A ticker pulls the page the rest of the way along a critically
  damped spring (`_onGlideTick`, 1/480 s substeps; eases in and out, no
  overshoot); a press adds a whole step, a held key's auto-repeat
  (`ReaderCommand.held`, set by ReaderKeyboard on `KeyRepeatEvent`) keeps
  the glide only the spring's lag ahead, so it moves a step every
  `heldStepSeconds` (70 ms) whatever the smoothness, and at the edge a held `←` `→` is
  swallowed so it doesn't run on through the pages. Key pans stop at the
  shown pages' edges (`_onPages`), not the letterbox a drag can reach, and
  don't move along a side the pages fit. Anything else setting the
  transform (a drag, a page turn, the camera) ends the glide. Reduced
  motion jumps. Tiles still wait for 150 ms of stillness. The step comes
  from `ScrollSpeed` (`scroll_speed.dart`, five notches, normal 15%),
  picked in Settings or with `g+` `g-` (`scrollFaster`/`scrollSlower`)
  and saved as `reader.scrollSpeed`; the spring from `ScrollSmoothness`
  (same file, time to 95%: crisp 0.15 s to smoothest 0.55 s, smooth 0.3 s
  by default), picked in Settings or with `g>` `g<`
  (`scrollSmoother`/`scrollCrisper`) and saved as
  `reader.scrollSmoothness`. app.dart handles all four keys.
  A key pan or a one-finger drag with guided view's dim up (a panel or a
  page part) widens the hole to take in the screen (`_lightSeen`,
  `_panned`), so nothing on screen stays dimmed; the next re-aim of the
  camera glides the hole back to the panel or part.
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
- The `?` help's text size (snonux, task 163): the help
  (`KeymapOverlay`, `lib/src/keymap_overlay.dart`) is shown at a step of
  `HelpZoom.scales` (`lib/src/help_zoom.dart`: ten factors, 0.7 to 3,
  the usual one 1), held by `helpZoomProvider` and kept as the setting
  `help.textSize` (the factor as a string, unset at the usual size). It
  is in `SettingsStore.backedUp` and `SettingsStore.sizes`, so a file's
  value must pass `parseSize`; `HelpZoom.parse` reads what is stored:
  no size (NaN, zero, negative, infinite, not a number) is the usual
  step, anything else the nearest step, clamped into the row first
  (from `1e300` every factor is equally far in doubles). `_takeUpImport`
  reloads it. HomeScreen watches the provider from the first build, so
  the size is read before the help is first opened. Keys: nothing is
  bound for it. `HomeScreen._onCommand` hands `zoomIn`/`zoomOut`/
  `zoomReset` to `_sizeHelp` (through `_helpTook`) while the help is up
  (a count is that many steps), before the line that keeps every other
  intent from the library and reader behind it, so a keys.toml of one's
  own works and the comic and covers behind are never sized. With the
  cursor in the help's search ReaderKeyboard makes no commands at all,
  so `+` and `-` are typed and searched for; Enter keeps the filter and
  hands the keys back. The overlay is wrapped in `GridZoomArea` for
  Ctrl+wheel, a touchpad pinch and two touch fingers, counting the
  largest text as one "column" and each smaller step as one more
  (`_columnsOf`). The size is applied as a `MediaQuery` text scaler over
  the search field and the list (the system's scaling of 14 px text
  times the factor; the system's own scaler untouched at the usual
  size); the version line is outside it. The layout goes by the letters
  as drawn, `_factor`: that scaler's effect on 14 px text, so the
  system's text scale times the help's factor. The key column is 200 px
  times it, and when that leaves the descriptions less than 70 px times
  it the keys go on a line above (`_row`); with the system's text at 1.5
  a 360 dp phone has them above at the usual size already. The title
  ("Keys · / searches · + - = text size · Esc closes", the size keys
  read from the keymap) and the notes under it are the first items of
  the list and scroll with it; only the search field is fixed above. They
  were fixed before, and at three times the size filled a phone's
  screen (a RenderFlex overflow in test/help_zoom_test.dart's narrow
  windows). A search that finds nothing says so in the middle of the
  room under the notes (`_nothing`, a `SliverFillRemaining` after the
  list's items in the one `CustomScrollView`). The version is a line of
  its own under the list (`_version`, in the outer Column, not over the
  list as before): right-aligned, and always at the system's text size,
  whatever the help's (it is not help text, and in 42 px letters it took
  a line some 100 px tall from a short window); a `FittedBox` shrinks it
  only where the window is narrower than the line.
  A size change keeps the item along the top of the list there, as far
  scrolled into it as it was; an item is an action's row, the title, a
  note, the gap under them or the parts note, each wrapped by `_item` in
  a `_Measured` under a GlobalKey (`_itemKeys`, in list order `_order`).
  `_keepPlace` (from `didUpdateWidget`, before the new layout) finds the
  item at the top edge and the share of it above the edge from the
  items' heights added up, and leaves `_PlaceController.place`, which
  `_PlacePosition.applyContentDimensions` takes up: that is called by
  the viewport once the items have their new heights, the position
  corrects its pixels (`_placeOf`) and answers false, and the viewport
  lays out once more at that offset, all before the frame is painted. So
  the first frame at the new size is right; a `jumpTo` after the frame
  showed one frame of other rows first. The heights are kept by
  `_RenderMeasured` in its own layout because a render object's `size`
  and `getOffsetToReveal` may not be read while an ancestor is laying
  out (a debug assertion). At offset 0 the list stays at the top. For
  all this the list lays out all of its items (`scrollCacheExtent` of
  `_wholeList`; 103 actions with the default keys plus the notes, only
  those on screen painted): laid out lazily it guessed its length and
  left the rows above the screen at the old size's offsets, and going by
  the share of its extent ended several rows off after one step. The
  cost, in a debug build's widget test at 1280x800 against a lazy list:
  opening the help 38 ms for 9 ms, a step 25 ms for 7 ms; nothing while
  scrolling. So in a widget test a row off screen is in the tree but
  offstage, which finders skip by default.
  `HomeScreen._helpTook` is the help's part of `_onCommand`: search,
  back, the size keys, and everything else but fullscreen kept from what
  is behind. No Settings entry and no touch button.
- The time (`T`, and a long press in the middle zone of every touch
  preset): `ReaderIntent.showTime`, handled in `HomeScreen._onCommand`
  before the library or reader see it, flashes `ClockFlash`
  (`lib/src/reader/clock_flash.dart`) over everything for 2 s, then a
  0.6 s fade (none with reduced motion). It sits in an `IgnorePointer`
  and formats with `MediaQuery.alwaysUse24HourFormat`. No setting.
- Android needs All files access (MANAGE_EXTERNAL_STORAGE), granted on a
  settings page; Android 7 to 10 ask for read and write storage at run
  time instead, with legacy storage on 10. `o` and `O` go through
  `MainActivity`'s own picker (`pickFile`, `pickFolder`), which answers
  with the real path (`pathOf`), not file_selector's copy in the cache.
  The reader sits in a SafeArea: Android 15 and a return from fullscreen
  draw the app edge to edge. Below 600 dp the status line puts its text
  above the buttons. Layout was tested on an Android 14 emulator; a real
  phone, pinch zoom and real speed and memory are untested. The
  shared-storage permission flow and file operations are also checked on
  Android 9/10/14 emulators; see `docs/android-storage-acceptance.md`.
  `usesAllFilesAccess` on the native storage channel tells the explanation
  (`lib/src/android_storage.dart`) whether to offer the runtime dialog or
  Settings; private app data does not use this gate.
- Tablets and split screen get no code of their own: every layout
  follows the window's width, the same on Linux. Library: bottom tabs
  below 600 dp, the rail from 600, the tab's name in the header from 840
  (the rail names it below), the details pane beside the covers from
  1000. Status line: text above the buttons below 600, counters before
  the title below 840, the file name from 1000; the two-page button
  (`spreadButton`) from 600, outside guided view. The decoded-page budget
  on Android (`pageBudgetBytes`) holds at least four screenfuls of the
  largest display, up to a thirty-second of the RAM, since a tablet page
  is some 16 MB. Tested on a Pixel Tablet emulator only; no real tablet.
- Settings → Export settings / Import settings (`SettingsFile` in
  `lib/src/data/settings_file.dart`, `lib/src/library/settings_transfer.dart`,
  the pickers in `HomeScreen._exportSettings`/`_importSettings`): one JSON
  file, `{"app": "org.snonux.comicredr", "kind": "settings", "format": 1}`
  plus the settings in `SettingsStore.backedUp` (a new setting goes there,
  or export leaves it out; `device.id`/`device.name` and
  `library.defaultFolderRemoved` stay per install and are never exported),
  the library folders, `keys.toml`'s text and the `progress`, `bookmarks`,
  `collection_books`, `overrides` and `read_log` rows by content key.
  Books, series, files, panels and covers stay out: a rescan and the
  sidecars rebuild them. A newer `format`, another `app` or not JSON is
  refused; unknown keys and broken rows are skipped and counted. Import
  sets the settings to the file's (missing ones back to default, except
  `SettingsStore.perInstall`, `sidecars.dir` and `sidecars.write`, which
  only change when the file sets them; a sidecar folder not on this
  device keeps this one), merges the rows by `mergeSidecars`' rules (the
  later position wins, history deduplicated) and adds folders that exist,
  all in one transaction; it never removes a library folder. Then it
  writes `keys.toml`, keeping a differing one as `keys.toml.bak` (a failure
  there is reported, the rest stands), and
  `_takeUpImport` reloads the reader, touch preset, shuffle, cover size, grid size,
  the help's text size and keymap (`reloadedKeymapProvider`) and rescans. Linux uses
  file_selector's save and open dialogs; Android `MainActivity`'s
  `pickFolder` (a new `comicredr-settings-DATE.json` in it, never
  overwriting) and `pickFile`, both real paths under All files access.
- S3 sync (design plan section 13): `packages/comic_sync` holds
  `RemoteStore`, `S3Store` (the `minio` package, path-style, region
  `garage` by default, 3 s connect timeout, `https_proxy` honoured),
  `checkConnection` and the shelf (`BookObjects`: `<prefix>books/<content
  key>/{manifest.json, comic.<ext> or files/…, cover.jpg, sidecar.crdb}`,
  the manifest written last and deleted first; `Manifest`; `listShelf`;
  `compareSidecars`). Settings → S3 sync (`s3_settings_dialog.dart`)
  saves `s3.endpoint`, `s3.region`, `s3.bucket`, `s3.prefix` and
  `s3.accessKey` as settings (exported, and `perInstall`, so a file
  without them leaves them); the secret key goes through `SecretStore`
  (`lib/src/data/secret_store.dart`): flutter_secure_storage (libsecret
  on Linux, so building needs `libsecret-1-dev` / `libsecret-devel`),
  and when the keyring does not answer within 3 s, a mode 0600
  `s3-secret` file beside keys.toml (`~/.config/comicredr/`), which is
  what Xvfb e2e runs use. `S3Settings.config()` reads the keyring only
  once the other settings are there. `S3Sync` (`lib/src/data/s3_sync.dart`,
  `s3SyncProvider`) works off the `s3_books` table (schema 11): a row per
  comic on the shelf, its manifest, `pending` (upload, sidecar, remove,
  sent oldest first by `drain`) and the bucket sidecar's `written_at`.
  `SidecarSync.onWritten` marks a synced comic's sidecar to go up after
  `pushDelay` (10 s); closing a book, pause and exit `flush`. Opening one
  runs `pullOnOpen` (2 s) before `attach`; a newer bucket sidecar replaces
  the local file and is imported whole (`attach(whole: true)`, no merge).
  The shelf is listed at start, resume, `R`, after a settings change and
  every 5 minutes; a comic without a local file is a `LibraryBook` with
  `s3.mark == S3Mark.remote` at the path a download would use (under the
  first library folder), which opens its page with Download instead of
  the reader. Downloads check the content key. An upload (`_upload`)
  of a comic already in the bucket (`_alreadyThere`: manifest there, the
  comic or every folder file at the manifest's size) sends nothing but
  meets the sidecars (`_meetSidecar`: push or pull, newest whole file
  wins) and keeps the bucket's manifest, so `gu` on a synced comic is a
  manual sync (`uploadBooks` passes every local book). The upload's
  share (`S3Status.transfers`) shows on the reader's status line
  (`StatusLine.s3Progress`). Unreachable: one notice,
  retry from 30 s doubling to 5 min, "S3 is back; N comics caught up".
  Keys `gu`, `gU`, `V` (marks, `_marked` in `LibraryScreenState`, with a
  bar over the grid; Ctrl+click; Select on a phone-wide header, Mark in
  the details pane or page). Delete
  of a comic on S3 offers Delete only here / Delete here and from S3
  (`DeleteChoice`). Tests override `secretStoreProvider` and
  `remoteStoreFactoryProvider`; `test/s3_sync_test.dart` runs two
  devices over a `MemoryStore`. The S3 tests in `packages/comic_sync`
  and the e2e run against `GARAGE_TEST_*` and are skipped without them;
  `tool/garage_local.sh start` runs a one-node Garage (static binary
  from garagehq.deuxfleurs.fr) and `eval "$(tool/garage_local.sh env)"`
  points them at it; `stop` plays a switched-off home cluster.
  `tool/e2e_s3_android.sh` needs the emulator (it reaches the host's
  Garage at 10.0.2.2). Never commit or post real bucket credentials.
  Android declares INTERNET and clear text (a home Garage is often plain
  http).
- Marking several comics (snonux, 2026-09-27): `_marked` in
  `LibraryScreenState` holds content keys, whatever tab or folder they
  were marked in. Shift+arrows, `S-Home`/`S-End` and Shift+click are runs
  (`ReaderIntent.markLeft` and friends, `_startRun`/`_markRun`): `_anchor`
  is the item the run started on and `_beforeRun` the marks before it,
  so the run is those plus every `BookItem` between anchor and cursor;
  any other intent or plain click ends the run (keeps the marks).
  `C-a` is `markAll`. In the reader app.dart turns the mark intents into
  the plain arrows. With marks, `gd`, `X` and `*` go to
  `lib/src/library/bulk_actions.dart` (one question for the lot:
  `askDeleteMany`, `askReset(count:)`); the bar's buttons too, plus
  Collection (`addBooksToCollection`, which asks through
  `askCollection(context, ref, what:, keys:)` for all of them). S3
  buttons show only when S3 is on. The marks clear once an action went
  ahead, not on Cancel.
  `gm` (`moveBooks`, the bar's Move) and `gc` (`addToCollection`) act on
  the marks, else the selected comic (`_markedOrSelected`). Move
  (`lib/src/library/move_books.dart`, snonux 2026-10-03): `moveTargets`
  lists every folder under the roots on disk on a short isolate (empty
  ones too; dot folders and folder books left out, links followed once),
  `MoveDialog` filters them by typed words (`matchesTarget`), Ctrl+N makes
  one in the picked folder and moves there. Taken names ask once
  (`askMoveClash`, Cancel focused; Replace deletes the one there through
  `deleteComic`). `moveComic`: `SidecarSync.flush`, `movePath` (rename,
  copy and delete across disks; a link is moved as a link, made
  absolute), `SidecarSync.moved` (beside and sidecar-folder copies),
  `LibraryStore.moveFile` (the `files` row follows unless a scan saw it
  first), so nothing keyed by content key changes.
- `make install` puts the bundle in `~/.local/lib/comicredr`, a symlink in
  `~/.local/bin` and the launcher and icons in `~/.local/share`; it never
  runs Flutter, so `sudo make install PREFIX=/usr/local` is safe, and
  `DESTDIR` is supported. `APK_ABI=android-arm64,android-x64` adds the
  emulator ABI to `make apk`; the APK carries only the ABIs asked for
  (`abiFilters` from `--target-platform`). `make push-keys` copies keys.toml to the
  phone.

## Layout

```
lib/                      Flutter app: library, reader screen, page cache, keyboard layer, Drift index
packages/comic_formats    ComicDocument, the CBZ, CBT, EPUB, PDF and folder adapters, the worker isolate, sniffing, sort
packages/comic_analysis   Panel model, classic-CV detection, reading order, the confidence gate
packages/reader_input     ReaderIntents, default keymap, vi key-sequence resolver
packages/comic_sync       S3 sync: RemoteStore, the S3 client, the connection check, the bucket layout
spike/                    M1 throwaway: classic-CV panel detection and overlays
test/corpus.manifest.toml Free test comics, fetched into git-ignored test/corpus/
```

## Develop and test

`flutter test` runs every test file under an empty scratch home
(`test/flutter_test_config.dart`, `debugUseHome` in `data_dirs.dart`):
widget tests run the real start-up, and with the real HOME they scanned
the developer's `~/Comics`, made a `~/Comics/.comicredr` and wrote test
positions into its sidecars. Code that reads HOME or the XDG variables
goes through `appEnvironment`, not `Platform.environment`.

Widget tests run on the test's clock; the app's database, its streams,
the scanner and a book's worker run in real time (`tester.runAsync`). Two
rules keep tests from failing or hanging on a busy machine (task 773):
check what real-time work leaves behind with `eventually` /
`eventuallyAsync` (`test/support/waits.dart`), never after a fixed while;
and run real-time work that touches the database through `whilePumping`,
not one `runAsync`: the app may hold the database in work that goes on
only when the test pumps, and a `runAsync` waiting for a query behind it
waits for good. Key sequences time out by `clock.now()`
(`ReaderKeyboard`), the test's clock in a widget test, so a test pumps
(`tester.pump(Duration)`) to let one lapse, and sends a sequence's keys
with no long pump between them. The e2e scripts count differing pixels
with `tool/differ_px.sh FUZZ A B [CROP]`, not compare's printed AE,
which ImageMagick 7 prints scaled and in exponent form.

The e2e scripts use the detector built into the release build (and pass
its file where they need one); `COMICREDR_MODEL=file.onnx` tries another,
`COMICREDR_MODEL=none` forces classic CV.

```sh
make dev                         # debug build with hot reload (r in the terminal)
make test                        # analyzer, format check and every test
make format                      # dart format at 120 columns (generated *.g.dart left alone)
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
tool/e2e_ahead.sh [corpus]     # panels found only for the open comic, ahead of the reader, guided view off; nothing with no comic open; stops on close; sidecar filled
tool/e2e_m9.sh book.cbz       # release tarball + install.sh, keys.toml, auto-trim, night filter, ? search, across restarts
tool/e2e_touch_linux.sh       # touch alone, no key or mouse: a comic opened from the library, every default reader gesture, the progress bar, the page grid pinched, scrolled and tapped, guided view, the back arrow out to the library, a long press on a cover; checks the view selects touch events and the index with sqlite3
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
tool/e2e_pause_whole.sh book.cbz [page]  # a page shown whole is wine red on arrival, a quick step zooms and holds once, a step after 2 s (then 5 s, set in the index) turns at once; keys and touches, both ways, a count, W across a restart (reptisaurus-v2-005 page 3)
tool/e2e_fullscreen.sh        # f and F11 under Openbox in Xvfb, plain and posing as GNOME Shell (header bar): window state, only the page, pointer, bottom edge, Esc, restart; makes its own book
tool/e2e_continue.sh         # C and the library's Continue button (tapped): the last comic's page after a restart, back and forth between two, guided view kept, a moved comic found, a deleted one skipped; makes its own books
tool/e2e_clock.sh            # T and a long press show the time for 2 s: fullscreen, windowed, the library; fades; makes its own book
tool/e2e_details.sh book.cbz book.pdf  # I: details over the reader, scrolled, a page picked from the list, a PDF's images, from the library
tool/e2e_completed.sh         # gC in the reader on and off, reading on to the last page marks a comic and G there does not, gC on a cover and u undoes it, F with Not completed and Completed only (each proved by the comic that opens first), kept across a restart, gC on a cover under the filter then Enter opens the cover next to it, Clear all, X Reset everything forgets the mark, a second install reads the marks from the sidecars; keyboard alone but for the tab click; checks the index and the sidecars with sqlite3; makes its own books
tool/e2e_favourites.sh        # * from the reader and on a cover, gf and the header star (found by comparing two screenshots, not at a fixed place), x takes one out, a restart; checks the index and a sidecar with sqlite3; makes its own books
tool/e2e_open_comic_collections.sh  # gc and * on the open comic: in the reader, over the page grid and over the bookmark list; the dialog seen by comparing screenshots, Esc in it, a name typed with no pause after gc, a collection it is in already (its row's added_at and removed_at unchanged seconds later), keys back with the grid, a restart (* and gc go by the index), a comic outside the library and its collection offered to a library comic, gc on a cover in the library with a name beginning gd X typed with no pause, then again with that name (row and sidecar unchanged); checks the index and the sidecars with sqlite3; makes its own books
tool/e2e_data_dir.sh          # app data in ~/Comics/.comicredr with fresh HOMEs: with ~/Comics, without it, an existing XDG database kept, ~/Comics a symlink (taken out stays out), a dangling one; nothing else written, .comicredr not in the library; makes its own books
tool/e2e_delete.sh             # gd and Shift+Delete: cancelled by Enter and Esc, then confirmed from the reader and the library; checks nothing lands in the trash, sidecars, index and thumbnails; makes its own books
tool/e2e_edit.sh a.cbz b.cbz folder/  # e: edit a book into another series, rename the series, restart, a second install reads the edits from the sidecars; checks both indexes and the sidecars
tool/e2e_shuffle.sh           # S and gs on the Folders tab over two CBZs, a PDF and a folder book: pages not covers, stable while moving, reshuffled, a book opens on page 1, kept across a restart
tool/e2e_search_key.sh        # / on the Folders tab: search, a click into a folder with the cursor in the box, / again selects the search, Enter, Esc; makes its own books
tool/e2e_rotate.sh            # > < 2> gr on a made book of coloured panels: the page turned, guided view across pages, zoom and j, a restart (index and sidecar), another book upright
tool/e2e_regions.sh book.cbz [page]  # H1 H2, B1-B3, L1-L4, Q1-Q4 and 11/00/21-54 on a page shown whole, in guided view and out: each part framed (tool/region_check.py), stepped, held, Esc; then by touch alone, the parts picker (two-finger tap, a part, edge taps, Stop parts); reptisaurus-v2-005 page 3
tool/e2e_symlinks.sh          # a library folder of links: a linked CBZ, folder of CBZs (with a loop), folder book and a dangling link; the watcher through a link, a sidecar beside the link, gd deletes only the link; makes its own books
tool/e2e_settings_backup.sh   # Settings → Export settings via the GTK save dialog with every setting changed (keys, the dialog, the index), keys.toml, folders, a position, bookmarks, a favourite, an edit, history; HOME wiped; Import via the open dialog: all back and live (fullscreen, scan, a keys.toml key), a restart, refused files, another device's file that must not touch the folders or sidecar place; checks the index with sqlite3; makes its own books
tool/e2e_s3_settings.sh      # Settings → S3 sync against GARAGE_TEST_* (tool/garage_local.sh): wrong key, server off, test and save, a restart, the secret only in its 0600 file, a settings export without it, turned off
tool/e2e_s3_android.sh app.apk # laptop (Xvfb) and phone (emulator) through a local Garage: V V gu uploads two, the phone lists them, downloads one, opens on the laptop's page and reads on; the laptop is offered the phone's place; gd here and from S3, gU; checks the bucket, the index and the phone's files
tool/e2e_s3_reader.sh         # two installs through a local Garage behind a slowed proxy: gu in the reader shows S3 ↑ n% on the status line; the same comic under another name on the second is not sent again, takes the newer sidecar, then pushes its own
tool/e2e_smooth_scroll.sh     # arrow keys on a zoomed page recorded at 60 fps with ffmpeg: a press glides (frames in between), a held key keeps going, Left/Right pan and stop at the page edge, a fresh press there turns; makes its own book
tool/e2e_pan_dim.sh           # H1 then ↓ ↓, H2 then k, a drag on Q1, j on a guided panel: nothing on screen left dimmed, the next step dims around again; makes its own book
tool/e2e_folder_filter.sh     # F on the Folders tab: by type, size and date picked with Tab and Space, each proved by the comic that opens first; kept across a restart; the x and the filter line clicked, Clear all; checks the index with sqlite3; makes its own books
tool/e2e_folder_sort.sh       # gS and Alt+P, S, M, L in its window, gO and go, each proved by the comic that opens first; kept across a restart; the sort button clicked; checks the index with sqlite3; makes its own books
tool/e2e_cover_zoom.sh        # + - = and Ctrl+wheel on the Folders tab, + then - keeps nothing, the same size on Books, a pinch by injected touches, a finger still scrolls and a tap still opens, a finger resting on the selected cover during a pinch opens nothing, + typed in the search box, Settings' Cover size buttons clicked (found from the dialog's end, so the checkout's path length does not move them), the size kept across a restart, a NaN size put in the index still shows covers; counts the covers in a row off screenshots and checks the index with sqlite3; makes its own books
tool/e2e_help_zoom.sh         # + - = in the ? help: the text a step bigger and smaller, the biggest (3x) and smallest (0.7x), the list still scrolling, Ctrl+wheel, + alone and - alone typed in the help's search (the list changes and the kept size does not) and + after Enter, a step some way down the list keeps the same keys along its top (told by how wide the first six lines of keys are; the measure first proved on two places a wheel notch apart), the version's line at the biggest text as at the usual size, the covers behind not sized and + with the help away sizing them, a restart, NaN, -12 and 1000000 put in the index; measures the title's first letter off screenshots and checks help.textSize in the index with sqlite3; makes its own books
tool/e2e_hotkeys.sh          # keys for buttons and dialogs, keyboard alone (the pointer parked below the window, no click): g, opens Settings, Tab and Space switch a setting, Tab and Right move a slider, Alt+H asks before clearing the history (Enter is Cancel, Alt+L clears), Alt+C closes; in a comic I, End and Alt+P redo its panels (analysed_pages newer than before) with the app still there (mm bookmarks the page and takes it off again, Esc the library as it was); gd with Tab and Shift+Tab moving the focus ring (screenshots differ and match again), d without Alt and Enter delete nothing, Alt+C cancels, Alt+D deletes; gc with ac typed at once and Alt+A, a name dropped by Alt+C; * gf x then u undoes; F with Space, Alt+C and Alt+D; gA takes the library folder out and u puts it back with its comics found again; the app has no session bus (no keyring) and no XDG folders of the caller; checks the index with sqlite3 and the comics on disk; makes its own books
tool/e2e_multi_select.sh     # Shift+arrows, Shift+End, Esc, Ctrl+A and * on six comics in a folder, X on two, gd on three (Enter cancels, then deleted), gm into a folder typed in the picker, Ctrl+N, a taken name skipped, gc, a restart; checks the index with sqlite3; makes its own books
python3 tool/e2e_android_storage.py SERIAL APK  # a dedicated ComicRedr_Acceptance_* AVD: OS-specific permission, deny/return and retry, private data, Comics/Download/Documents, sidecars, export and cancelled/confirmed deletion; see docs/android-storage-acceptance.md
tool/guide_shots.sh [section...]  # the usage guide's screenshots and GIFs into docs/guide/images/, from the fetched corpus and Pepper&Carrot; the app's HOME is /tmp/comicredr-guide/home (GUIDE_HOME), never under the checkout, since the ? help and Settings show the data folder's path and with it the name of whoever took the pictures
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

The full recipe, for people and agents alike, is
[docs/training.md](docs/training.md): what the shipped model is, the one
command that rebuilds it, the licence rules, adding books and labels,
scoring and shipping. The notes below add the history.

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
python3 -m pip install --user -r spike/requirements-train.txt   # the versions the shipped model used
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
