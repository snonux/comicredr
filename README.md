# ComicRedr

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Quick start on Fedora

> **Current state (M6):** CBZ files, PDFs and folders of page images open
> and read in single-page or two-page mode or in guided view, panel by
> panel or balloon by balloon, with zoom, the full keymap, touch gestures,
> and resume. Guided view uses the trained panel and balloon detector when
> it is installed (step 6) and classic computer vision otherwise. The
> library (M7) is still to come.

### 1. Install the build tools and Flutter

```sh
sudo dnf install git clang cmake ninja-build pkgconf-pkg-config gtk3-devel
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

### 2. Build and start

```sh
git clone https://github.com/snonux/comicredr.git && cd comicredr
flutter pub get
flutter run -d linux                  # debug build, hot reload with r
```

For a standalone release build:

```sh
flutter build linux --release
./build/linux/x64/release/bundle/comicredr
```

The `bundle/` directory is self-contained. Copy it anywhere, for example
`~/.local/opt/comicredr`, and start the `comicredr` binary inside it.

### 3. Open a comic book

A book is a `.cbz`, a `.pdf`, or a folder of page images. Any of these
opens one straight away, without adding it to a library:

- pass it on the command line: `comicredr ~/Comics/Daredevil\ 181.cbz`,
  `comicredr ~/Comics/Swamp\ Thing\ 21.pdf` or `comicredr ~/Comics/Preacher\ 01/`
- press `o`, or click **Open a comic**, for a file picker (CBZ and PDF)
- press `O`, or click **Open a folder**, to pick a folder of page images
- drag the file or folder onto the window

Close the book or the app and the book reopens exactly where you left it:
the same page, in the same view (single page, spread, or guided view on the
same panel, and balloon mode on the same balloon), with the same zoom and
scroll. This holds after you rename or copy the file, because progress is
keyed on the file's content rather than its path. A book you have never
opened starts on its cover in the view you are reading in. `]` and `[` open
the next and previous book in the same folder, CBZs, PDFs and folder books
alike, in natural name order. `Esc` closes the book.

The file's first bytes decide how it is read, not its extension, so a `.cbr`
that is really a ZIP opens as-is.

- **PDFs** render through PDFium at the size they are shown at, never above
  300 dpi, so a 600 dpi scan does not become a giant bitmap. On this
  container's CPU a page takes about a quarter of a second at screen size
  and just under a second at 2048 pixels wide, which is what guided view
  asks for; the page you turn to renders before the pages being prefetched.
  PDFium comes with the build: the first `flutter build` or `flutter run`
  downloads it once, so that one needs the network.
- **Folders** read their JPEG, PNG, WebP, GIF and BMP files as pages,
  subfolders included, in natural order (`page2` before `page10`), skipping
  dotfiles and `Thumbs.db`. A `ComicInfo.xml` inside the folder supplies
  the title and series. Progress follows the folder when you rename it, as
  it does for files.

#### The CBR files you already have

A genuine RAR is refused with a message pointing here. Convert it once to
CBZ. This takes a couple of seconds a book, and the CBZ opens faster:

```sh
sudo dnf install unar zip
for f in *.cbr; do
  d=$(mktemp -d)
  unar -q -o "$d" "$f"
  (cd "$d" && zip -qr0 "$OLDPWD/${f%.cbr}.cbz" .)
  rm -rf "$d"
done
```

### 4. Navigate

Two keymaps are live at the same time: standard keys, and a vi layer on top
of them. You don't need to learn the vi layer to use the reader. Press `?`
to see the full keymap in the app. The overlay is generated from the same
table the app binds from.

| Do this | Standard | vi |
|---|---|---|
| Next / previous step (a panel in guided view, a page otherwise) | `→` `←`, `Space` `Shift+Space` | `l` `h` |
| Next / previous page, skipping panels | `PgDn` `PgUp` | `Ctrl+f` `Ctrl+b` |
| Pan, or scroll in continuous mode | `↓` `↑` | `j` `k`, `Ctrl+d` `Ctrl+u` for half a screen |
| First / last page | `Home` `End` | `gg` `G`, and `42G` goes to page 42 |
| Guided view on and off | | `v` |
| Balloon by balloon inside each panel, on and off | | `b` |
| Cycle single page, spread, guided view | `Tab` `Shift+Tab` | |
| Switch between single page and spread | | `d` |
| Shift the spread pairing by one page | | `D` |
| Fit width, height or whole page; in guided view `zz` re-centres the panel | | `zw` `zh` `zz` |
| Zoom in, out, reset | `+` `-` `=` | |
| Hide the status line (and system bars on Android) | `F11` | `f` |
| Night filter | | `i` |
| Set mark a–z / jump to mark / jump back | | `ma` / `'a` / `''` |
| Next / previous book in the same folder (the series, once the library lands in M7) | | `]` `[` |
| Leave guided view, close the book, or cancel a half-typed key | `Esc` | |
| Open a CBZ or PDF / a folder of page images | | `o` / `O` |

The status line shows the page you are on out of the total (`page 3 / 36`),
and in guided view the panel too (`guided: panel 2 / 6`). A thin bar along
the bottom of the page shows how far through the book you are, and stays
visible when `f` hides the status line.

A count in front of a key repeats it: `5l` moves five pages (five panels
in guided view), and `3 Ctrl+f` turns three pages. Marks are saved
and survive a restart, and in guided view they remember the panel. A
bookmark list arrives with the library in M7. A key
whose feature has not landed yet says so on the status line. A half-typed sequence such as `g` or `4z`
shows in the bottom-right corner. It is dropped if you don't finish it
within 600 ms.

### 5. Guided view

Press `v`. The camera frames the first panel on the page and dims the rest,
and `l`, `→` or `Space` glides to the next panel, onto the next page after
the last one. `h` goes back. `Ctrl+f` or `PgDn` skips to the next page's
first panel. `+` and `-` zoom within a panel and `zz` re-centres it. `v`
again returns to single page or spread, whichever you came from, and `v`
once more comes back to the same panel. Reopening a book remembers the
panel you stopped on, even after a restart; press `v` to pick up there.

Panels are found on the laptop's CPU in the background, about a quarter of
a second a page, starting with the page you are on and the two after it.
The results are cached in the app's database, so a page is only analysed
once. While a page is still being analysed the status line says
`finding panels…` and shows the whole page.

A page whose panels don't look like a real layout is shown whole rather
than guessed at: a splash, a cover, a text page and many ads. The status
line says why, for example `guided: whole page (1 panel(s): nothing to
guide through)`. Without the trained detector (step 6), pages without
gutters between panels, and many ads, still trip it up.

**Balloon by balloon.** Press `b` for balloon mode, from guided view or
straight from the page. Each panel is shown whole first, then every speech
balloon and caption in it, one step at a time, in reading order, with a
little of the art around it so you see who is talking. A panel with no
balloons is one step, as before. The status line reads
`guided: panel 2 / 6  ·  balloon 1 / 3`. Keys, taps and swipes all step the
same way, and `b` again goes back to panel by panel at the same panel.
Balloons come from the trained detector; with classic CV the status line
says `no balloons found` and balloon mode steps panels only.

### 6. Install the trained detector

The trained model finds panels on pages classic CV gets wrong (borderless
art, ads, captions) and is the only source of balloons. It is one file,
`comicredr-panels.onnx`, kept out of this public repository because it
starts from a model trained on Manga109, whose data is for research use.
Copy it into the app's data folder once:

```sh
mkdir -p ~/.local/share/org.snonux.comicredr/models
cp comicredr-panels.onnx ~/.local/share/org.snonux.comicredr/models/
```

On Android put it in `Android/data/org.snonux.comicredr/files/models/` on
the phone's storage, for example with
`adb push comicredr-panels.onnx /sdcard/Android/data/org.snonux.comicredr/files/models/`.
Restart the app. `COMICREDR_MODEL=/path/to/file.onnx` points at a model
anywhere else. Pages analysed by classic CV are analysed again with the
model the next time you read them. To build the file yourself, see
[Train the detector](#m5-train-the-detector).

### 7. Touch

A touchscreen works the same on the Fedora laptop as on the phone, and every
gesture does what the matching key does. A mouse click never turns a page,
so clicking into the window is safe.

| Do this | Touch | Same as |
|---|---|---|
| Next / previous step (a panel or balloon in guided view, a page otherwise) | tap the right or left edge, or swipe left or right | `→` `←` |
| Zoom | pinch with two fingers, or double-tap the middle to zoom in on that spot | `+` `-` |
| Back to the whole page, or re-centre the panel in guided view | double-tap the middle again | `=`, `zz` |
| Move around a zoomed page | drag with one finger | `↓` `↑` |
| Hide or show the status line | tap the middle | `F11` |

The edges are the outer 30% of the screen on each side. A swipe on a
zoomed page pans it instead of turning; swipe again once it stops at the
edge of the page to turn. In guided view a swipe always moves to the
next or previous panel, and one finger does not pan there. Right to left books mirror taps and swipes just
as they mirror the arrow keys. A touchpad pinch zooms too.

## Layout

```
lib/                      Flutter app: reader screen, page cache, keyboard layer, Drift index
packages/comic_formats    ComicDocument, the CBZ adapter and its worker isolate, sniffing, sort
packages/comic_analysis   Panel model, classic-CV detection, reading order, the confidence gate
packages/reader_input     ReaderIntents, default keymap, vi key-sequence resolver
spike/                    M1 throwaway: classic-CV panel detection and overlays
test/corpus.manifest.toml Free test comics, fetched into git-ignored test/corpus/
```

## Develop

```sh
dart run build_runner build -d   # regenerate Drift code after schema edits
flutter analyze && flutter test
for p in packages/*; do (cd $p && dart test); done
(cd packages/comic_analysis && dart run tool/detect_pgm.dart page.pgm)  # Dart detector on one page, to compare with spike/detect_cv.py
tool/e2e_linux.sh [book.cbz|book.pdf|folder]  # release build under Xvfb, driven by real keys incl. guided view and by injected GTK touches, screenshots in build/e2e/
tool/e2e_resume.sh book.cbz   # closes and reopens the release build mid-panel, mid-balloon, zoomed, and killed; fails if the view differs
```

## M1 detection spike

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

## M5: train the detector

Everything runs on the CPU; a 40-epoch fine-tune takes about an hour and a
half on 4 cores. The labels are committed in `spike/labels/` (how they were
drawn: `spike/LABELLING.md`); the comics are fetched.

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics onnx onnxruntime onnxslim
python3 spike/fetch_corpus.py                                   # eval comics + the Manga109 model
python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train
python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 10
python3 spike/extract_pages.py test/corpus-train spike/train_pages --per-book 12 --manifest test/train.manifest.toml
python3 spike/labelkit.py import spike/labels/eval spike/eval_pages
python3 spike/labelkit.py import spike/labels/train spike/train_pages
python3 spike/train.py spike/train_pages --out spike/out/train  # -> spike/out/train/run/weights/best.pt
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
