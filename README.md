<p align="center">
  <img src="linux/packaging/org.snonux.comicredr.svg" alt="ComicRedr icon" width="128">
</p>

<h1 align="center">ComicRedr</h1>

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Screenshots

| | |
|---|---|
| ![A page of All Top Comics in single-page view](docs/screenshots/page.webp) | ![A two-page spread of Pepper&Carrot](docs/screenshots/spread.webp) |
| Single page, with the page counter and progress bar | Two-page spread (`d`) |
| ![Guided view framing one panel, the rest of the page dimmed](docs/screenshots/guided.webp) | ![Balloon mode zoomed in on one speech balloon](docs/screenshots/balloon.webp) |
| Guided view (`v`) on panel 2 of 6, found by the trained detector | Balloon mode (`b`) steps through the speech balloons in each panel |
| ![Guided view on a painted modern page](docs/screenshots/guided-painted.webp) | ![The night filter on a page](docs/screenshots/night.webp) |
| Guided view on painted art with no gutters | Night filter (`i`) |

Taken from the release build on Linux. The books are *All Top Comics* 6
(Norlen, 1959; public domain, its copyright was not renewed; from the
Digital Comic Museum's archive.org mirror) and
[Pepper&Carrot](https://www.peppercarrot.com) episode 6, *The Potion
Contest*, by David Revoy, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Quick start on Fedora

> **Current state (M7):** a library of your comics folders, with covers,
> series, search and bookmarks. CBZ files, PDFs and folders of page images
> read in single-page or two-page mode or in guided view, panel by panel or
> balloon by balloon, with zoom, the full keymap, touch gestures, and
> resume. Guided view uses the trained panel and balloon detector when it
> is installed (step 7) and classic computer vision otherwise. Per-comic
> sidecar files (M8) are still to come.

### 1. Install the build tools and Flutter

```sh
sudo dnf install git clang cmake ninja-build pkgconf-pkg-config gtk3-devel
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

### 2. Build, start and install

```sh
git clone https://github.com/snonux/comicredr.git && cd comicredr
make                  # release build, into build/linux/x64/release/bundle/
make run              # build if needed, then start it
make run BOOK=~/Comics/Daredevil\ 181.cbz    # start straight on a book
make install          # add ComicRedr to the GNOME app grid, no sudo
```

`make install` puts the app in `~/.local/lib/comicredr`, a `comicredr`
command in `~/.local/bin`, and a launcher with its icon in
`~/.local/share`. ComicRedr then shows up in Activities like any other app,
with its own icon in the dash, and **Open With → ComicRedr** works on CBZ
and PDF files in Files. Run `make install` again after `git pull && make`
to update, and `make uninstall` to remove it; your reading progress and the
detector model stay. For a system-wide install, run `make` first and then
`sudo make install PREFIX=/usr/local`.

`make dev` starts a debug build with hot reload (`r` in the terminal),
`make test` runs the analyzer and every test, and `make help` lists all
targets.

### 3. Build your library

The library is where ComicRedr starts. Press `A`, or click **Add your
comics folder**, and pick the folder your comics live in, for example
`~/Comics`. Add as many folders as you like; subfolders are searched too.
From the command line, `comicredr --add-root ~/Comics` does the same.

Every CBZ, PDF and folder of page images under it turns up as a cover.
The first scan reads each book once, a few at a time in the background,
for its page count, its metadata and a cover: about a third of a second a
book on this container's CPU, a second for a big scan. You can browse and
read while it runs; the status line counts it down. After that, starting
the app only compares file sizes and dates, so a library that has not
changed is ready at once. Files you add, rename or delete under a library
folder show up by themselves a couple of seconds later. `R` rescans by
hand. A file that looks like a comic but can't be read, such as a genuine
RAR, is listed with the reason on the **Folders** tab.

Metadata comes from the `ComicInfo.xml` inside a CBZ or a folder when
there is one, and from the file name otherwise:
`Daredevil v1 #181 (1982).cbz`, `Daredevil_181.cbz` and
`daredevil-181.cbz` all read as Daredevil, number 181. Books group into a
series by that name, whatever folders they are in, and read in issue order.

The library has four tabs: **Reading** (books you have started, the one
you read last first), **Series**, **Books** (everything, series by series)
and **Folders** (the folders in the library, to add, remove or rescan).
Removing a folder leaves the files alone and keeps your reading progress
for when they come back.

| Do this | Keys | Touch or mouse |
|---|---|---|
| Move between covers | arrows, or `h` `j` `k` `l`; `gg` `G` for the first and last | |
| Open a series, or read a book | `Enter` | tap a series; tap a selected book again |
| See a book's details, progress and bookmarks | select it; on a narrow window `Enter` reads straight away | tap it on a narrow window, long-press anywhere |
| Search titles, series, creators and years | `/`, type, `Enter` to go back to the covers | the search field |
| Next / previous tab | `Tab` `Shift+Tab` | the tabs at the side or bottom |
| Back out of the details, the search or a series | `Esc` | the back arrow |
| Add a folder / rescan | `A` / `R` | the folder button, or the **Folders** tab |

On a wide window the selected book or series shows beside the covers, with
**Continue reading** and its bookmarks. `Esc` in the reader closes the
book and comes back to the library where you were. In the reader, `]` and
`[` go to the next and previous book in the series.

On Android the library needs **All files access**, which Android grants
on a settings page rather than in a dialog. The first time you add a
folder the app explains this and opens that page; turn it on, come back,
and add the folder, for example `/storage/emulated/0/Comics`. The phone
rescans each time the app comes back to the front.

### 4. Open a single comic

A book is a `.cbz`, a `.pdf`, or a folder of page images. Any of these
opens one straight away, without adding it to the library:

- right-click it in Files and pick **Open With → ComicRedr** (after
  `make install`)
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
the next and previous book in the series when the book is in the library
with others in its series, and otherwise the next and previous book in the
same folder, CBZs, PDFs and folder books alike, in natural name order.
`Esc` closes the book and goes back to the library.

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

### 5. Navigate

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
| Whole page before and after its panels in guided view, on and off (on by default) | | `w` |
| Cycle single page, spread, guided view | `Tab` `Shift+Tab` | |
| Switch between single page and spread | | `d` |
| Shift the spread pairing by one page | | `D` |
| Fit width, height or whole page; in guided view `zz` re-centres the panel | | `zw` `zh` `zz` |
| Zoom in, out, reset | `+` `-` `=` | |
| Hide the status line (and system bars on Android) | `F11` | `f` |
| Night filter | | `i` |
| Set mark a–z / jump to mark / jump back | | `ma` / `'a` / `''` |
| Next / previous book in the series (in the same folder, outside the library) | | `]` `[` |
| Bookmark this page (this panel in guided view) | | `mm` |
| Leave guided view, go back to the library, or cancel a half-typed key | `Esc` | |
| Open a CBZ or PDF / a folder of page images | | `o` / `O` |

The status line shows the page you are on out of the total (`page 3 / 36`),
and in guided view the panel too (`guided: panel 2 / 6`). A thin bar along
the bottom of the page shows how far through the book you are, and stays
visible when `f` hides the status line.

A count in front of a key repeats it: `5l` moves five pages (five panels
in guided view), and `3 Ctrl+f` turns three pages. Marks are saved
and survive a restart, and in guided view they remember the panel. `mm`
adds a bookmark, as many as you like. The book's details in the library
list its bookmarks and marks; pick one to open the book there. A key
whose feature has not landed yet says so on the status line. A half-typed sequence such as `g` or `4z`
shows in the bottom-right corner. It is dropped if you don't finish it
within 600 ms.

### 6. Guided view

Press `v`. The page is shown whole first, so you see its layout, then
`l`, `→` or `Space` glides into the first panel and dims the rest, and on
panel by panel. After the last panel the camera pulls back to the whole
page once more, and the next step turns to the next page, again shown
whole. `h` goes back the same way. `Ctrl+f` or `PgDn` skips to the next
page, shown whole. `+` and `-` zoom within a panel and `zz` re-centres it.

The whole-page steps are on by default. Press `w` to go straight from panel
to panel across pages instead, and `w` again to bring them back; the choice
is kept across restarts. A page that is only ever shown whole (a splash,
a cover) is one step either way. `v`
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
guide through)`. Without the trained detector (step 7), pages without
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

### 7. Install the trained detector

The trained model finds panels on pages classic CV gets wrong (borderless
art, ads, captions) and is the only source of balloons. It is one file,
`comicredr-panels.onnx`, kept out of this public repository because it
starts from a model trained on Manga109, whose data is for research use.
Copy it into the app's data folder once:

```sh
make install-model MODEL=path/to/comicredr-panels.onnx
```

This copies it to `~/.local/share/org.snonux.comicredr/models/`.

On Android put it in `Android/data/org.snonux.comicredr/files/models/` on
the phone's storage, for example with
`adb push comicredr-panels.onnx /sdcard/Android/data/org.snonux.comicredr/files/models/`.
Restart the app. `COMICREDR_MODEL=/path/to/file.onnx` points at a model
anywhere else. Pages analysed by classic CV are analysed again with the
model the next time you read them. To build the file yourself, see
[Train the detector](#m5-train-the-detector).

### 8. Touch

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
lib/                      Flutter app: library, reader screen, page cache, keyboard layer, Drift index
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
for p in packages/*; do (cd $p && dart test); done   # make test runs all three
make icons                       # re-render linux/packaging/icons/*.png after editing the SVG
(cd packages/comic_analysis && dart run tool/detect_pgm.dart page.pgm)  # Dart detector on one page, to compare with spike/detect_cv.py
tool/e2e_linux.sh [book.cbz|book.pdf|folder]  # release build under Xvfb, driven by real keys incl. guided view and by injected GTK touches, screenshots in build/e2e/
tool/e2e_library.sh           # library over the fetched corpus: scan, covers, series, search, ] [, bookmarks, live folder changes, restart, phone layout and touch; checks the index with sqlite3
tool/e2e_resume.sh book.cbz   # closes and reopens the release build mid-panel, mid-balloon, zoomed, and killed; fails if the view differs
tool/e2e_whole_page.sh book.cbz [page]  # guided view's whole-page steps with keys and touches, both ways, w on and off, across restarts; fails if a step shows the wrong view
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
