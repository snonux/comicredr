# AGENTS.md

Notes for coding agents and contributors working on ComicRedr. The
[README](README.md) is for people using the app; keep it short and put
build internals, test scripts, detector work and conventions here.

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
  `apt-get install libgtk-3-dev xvfb xdotool imagemagick` first; most also
  use `sqlite3` and Python with Pillow.
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
- The detector model is loaded from
  `~/.local/share/org.snonux.comicredr/models/`
  (`Android/data/org.snonux.comicredr/files/models/` on the phone), the app
  bundle, or `COMICREDR_MODEL=/path/to/file.onnx`.
- Sidecars: `book.cbz.crdb` beside the file, `.comicredr.crdb` inside a
  folder book. They hold metadata, panels and balloons, bookmarks, marks,
  collections and per-device positions. Removed bookmarks stay removed
  when an older sidecar comes back. Unwritable folders fall back to the
  app database; Settings → Export sidecars writes them to a tree elsewhere.
  `X` (or Reset in the book's details) resets a comic: `SidecarSync.reset`
  deletes its rows and rewrites every copy's sidecar without them, since a
  sidecar left alone would merge them straight back in.
  Inspect one with
  `sqlite3 'book.cbz.crdb' 'select page, kind, x, y, w, h from panels'`.
- Non-rectangular panels: the detector outputs boxes; `refineOutlines`
  traces the real outline along the gutter and the reader dims outside
  it, while the camera frames the box.
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
COMICREDR_MODEL=model.onnx tool/e2e_modern.sh  # guided view on real modern comics from test/corpus-modern, screenshots in build/e2e-modern/
tool/e2e_library.sh           # library over the fetched corpus: scan, covers, series, search, ] [, bookmarks, live folder changes, restart, phone layout and touch; checks the index with sqlite3
COMICREDR_MODEL=comicredr-panels.onnx tool/e2e_sidecar.sh a.cbz b.pdf folder/  # two installs as laptop and phone: sidecar written, copied and renamed, re-linked, resumed without detecting, position offered back; plus a read-only shelf
tool/e2e_m8_library.sh        # collections made from book details, a sitting in the history, the settings dialog, a restart; checks the index and a sidecar with sqlite3
tool/e2e_resume.sh book.cbz   # closes and reopens the release build mid-panel, mid-balloon, zoomed, and killed; fails if the view differs
COMICREDR_MODEL=model.onnx tool/e2e_margins.sh  # guided view on eval pages padded with a wide scanned margin; checks the index records the trim
tool/e2e_whole_page.sh book.cbz [page]  # guided view's whole-page steps with keys and touches, both ways, w on and off, across restarts; fails if a step shows the wrong view
tool/e2e_library_detection.sh [corpus] [model]  # whole-library panel pass: starts by itself, resumes after a kill, fills sidecars
tool/e2e_m9.sh book.cbz       # release tarball + install.sh, keys.toml, auto-trim, night filter, ? search, across restarts
tool/e2e_reset.sh book.cbz     # X: redo panels, then reset everything from the reader, then from the library's book details; checks the index and the sidecar
tool/e2e_formats.sh           # CBT and EPUB: real files from test/formats.manifest.toml; library, same pixels as the CBZ, refused ebooks
(cd packages/comic_formats && dart run tool/inspect_book.dart book.epub)  # what the format layer makes of a book, or why it refuses it
```

## Detection spike (M1)

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics
python3 spike/make_synthetic.py                       # synthetic pages with ground truth
python3 spike/fetch_corpus.py                         # real comics + pretrained model
python3 spike/extract_pages.py test/corpus spike/pages
cd spike && python3 run_spike.py pages out --weights ../test/corpus/models/<model>.pt
```

`out/contact.jpg` shows every overlay: green boxes passed the confidence
gate, red ones fell back to plain paging, blue are the pretrained detector's
frames, magenta its balloons. Pages are sampled into one folder per style
(from the manifest's `style` field), `out/contact-<style>.jpg` puts classic
CV and the pretrained model side by side for each style, and `results.json`
carries a per-style summary.

## Train the detector (M5)

Everything runs on the CPU; a 40-epoch fine-tune takes about an hour and a
half on 4 cores. The labels are committed in `spike/labels/` (how they were
drawn: `spike/LABELLING.md`); the comics are fetched.

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics onnx onnxruntime onnxslim
python3 spike/fetch_corpus.py                                   # eval comics + the Manga109 model
python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train
python3 spike/fetch_corpus.py --manifest test/modern.manifest.toml --out test/corpus-modern --skip-model
python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 400
python3 spike/extract_pages.py test/corpus-train spike/train_pages --per-book 400 --manifest test/train.manifest.toml
python3 spike/extract_pages.py test/corpus-modern spike/modern_pages --per-book 400 --manifest test/modern.manifest.toml
python3 spike/labelkit.py import spike/labels/eval spike/eval_pages
python3 spike/labelkit.py import spike/labels/train spike/train_pages
python3 spike/labelkit.py import spike/labels/modern spike/modern_pages
python3 spike/train.py spike/train_pages --out spike/out/train --epochs 45  # -> spike/out/train/run/weights/best.pt
python3 spike/export_onnx.py spike/out/train/run/weights/best.pt --out spike/out/comicredr-panels.onnx --int8 spike/train_pages
cd spike && python3 evaluate.py eval_pages --out out/eval --pretrained ../test/corpus/models/best.pt \
    --trained out/comicredr-panels.onnx                          # out/eval/report.md
```

`evaluate.py` scores classic CV, the downloaded Manga109 model and the
fine-tune on the same 100 labelled pages, none of them from a training
book: panel and balloon F1 at IoU 0.5, and per page whether guided view
would move the camera right, show the page whole, or move it wrong.

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
