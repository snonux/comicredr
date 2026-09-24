<p align="center">
  <img src="linux/packaging/org.snonux.comicredr.svg" alt="ComicRedr icon" width="128">
</p>

<h1 align="center">ComicRedr</h1>

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Screenshots

![The library: series of covers, with the selected book's details beside them](docs/screenshots/library.webp)

The library: every book in your comics folders as a cover, grouped by
series, with the selected book's details beside them.

| | |
|---|---|
| ![A page of All Top Comics in single-page view](docs/screenshots/page.webp) | ![A two-page spread of Pepper&Carrot](docs/screenshots/spread.webp) |
| Single page, with the page counter and progress bar | Two-page spread (`d`) |
| ![Guided view framing one panel, the rest of the page dimmed](docs/screenshots/guided.webp) | ![Balloon mode zoomed in on one speech balloon](docs/screenshots/balloon.webp) |
| Guided view (`v`) on panel 2 of 6, found by the trained detector | Balloon mode (`b`) steps through the speech balloons in each panel |
| ![Guided view on a painted modern page](docs/screenshots/guided-painted.webp) | ![The night filter on a page](docs/screenshots/night.webp) |
| Guided view on painted art with no gutters | Night filter (`i`) |

Taken from the release build on Linux. The comics are golden- and
silver-age books that are in the public domain because their copyright
was not renewed, from the Digital Comic Museum's archive.org mirror (the
reader screenshots show *All Top Comics* 6, Norlen, 1959), and
[Pepper&Carrot](https://www.peppercarrot.com) episode 6, *The Potion
Contest*, by David Revoy, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Quick start on Fedora

> **Current state (M8):** a library of your comics folders, with covers,
> series, search and bookmarks. CBZ files, PDFs and folders of page images
> read in single-page or two-page mode or in guided view, panel by panel or
> balloon by balloon, with zoom, the full keymap, touch gestures, and
> resume. Guided view uses the trained panel and balloon detector built
> into the app (step 7) and classic computer vision otherwise. Each comic
> carries its panels, bookmarks and position in a sidecar file beside it
> (step 9). Collections, reading history and settings are still to come.

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
make model MODEL=path/to/comicredr-panels.onnx   # once, see step 7
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
to update, and `make uninstall` to remove it; your reading progress and any
model you installed with `make install-model` stay. For a system-wide install, run `make` first and then
`sudo make install PREFIX=/usr/local`.

`comicredr --version` (or `make version` in the checkout) prints the
version, which the library's status line and the `?` overlay also show. What each
version brought is in [CHANGELOG.md](CHANGELOG.md).

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

Modern layouts (panels of different sizes, slanted frames, insets,
borderless art) need the trained detector from 2026-09-24 or later; on the
66-page modern test set it guides 49 pages right, shows 15 whole and
moves wrongly on 2. A two-page spread (a landscape page image) reads the
whole left page before the right one. Slanted panels are still framed by
their box, so a sliver of the neighbouring panel stays lit, and a page
whose slanted panels overlap a lot is shown whole.

**Balloon by balloon.** Press `b` for balloon mode, from guided view or
straight from the page. Each panel is shown whole first, then every speech
balloon and caption in it, one step at a time, in reading order, with a
little of the art around it so you see who is talking. A panel with no
balloons is one step, as before. The status line reads
`guided: panel 2 / 6  ·  balloon 1 / 3`. Keys, taps and swipes all step the
same way, and `b` again goes back to panel by panel at the same panel.
Balloons come from the trained detector; with classic CV the status line
says `no balloons found` and balloon mode steps panels only.

### 7. The trained detector

The trained model finds panels on pages classic CV gets wrong (borderless
art, ads, captions) and is the only source of balloons. It is one file,
`comicredr-panels.onnx`, that the build packs into the app: `make` puts it
in the Linux bundle and `make apk` in the APK, so an installed ComicRedr
needs no separate model step. The build takes it from
`assets/models/comicredr-panels.onnx`, which git ignores: the file is kept
out of this public repository because it starts from a model trained on
Manga109, whose data is for research use. Put it there once per checkout:

```sh
make model MODEL=path/to/comicredr-panels.onnx
```

`make` and `make apk` stop with a message saying so when it is missing;
`make NO_MODEL=1` builds without it, and the app then uses classic CV.

To try another model without rebuilding, `make install-model
MODEL=other.onnx` copies it to `~/.local/share/org.snonux.comicredr/models/`,
where it wins over the built-in one (delete it there to go back). On the
phone `make push-model MODEL=other.onnx` does the same over USB (see
[Android phone](#android-phone)). `COMICREDR_MODEL=/path/to/file.onnx`
points at a model anywhere else, and `COMICREDR_MODEL=none` forces
classic CV. Pages analysed by classic CV, or by a different model file,
are analysed again the next time you read them, so a new model needs
nothing else. To build the file yourself, see
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
| Guided view on or off | the panels button at the right of the status line | `v` |
| Balloon by balloon, in guided view | the speech-balloon button next to it | `b` |
| Bookmark the page (the panel in guided view) | the bookmark button | `mm` |
| Leave guided view, then the book | Android's back gesture or button | `Esc` |

The edges are the outer 30% of the screen on each side. A swipe on a
zoomed page pans it instead of turning; swipe again once it stops at the
edge of the page to turn. In guided view a swipe always moves to the
next or previous panel, and one finger does not pan there. Right to left books mirror taps and swipes just
as they mirror the arrow keys. A touchpad pinch zooms too.

### 9. Take a comic to another machine

Every comic you open gets a small SQLite file beside it holding what the
app knows about it: the detected panels and balloons, your bookmarks and
marks, and where you stopped. `Daredevil 181.cbz` gets
`Daredevil 181.cbz.crdb`; a folder of page images keeps
`.comicredr.crdb` inside itself. The comic itself is never touched.

Copy the comic together with its `.crdb` to the phone (or another
folder, or another laptop) and it opens there with guided view ready,
without running the detector again, on the page you left it. The library
ignores `.crdb` files, and a sidecar left behind when you rename a comic
is found again by its content.

Positions are kept per device. When you open a comic that was read
further on another machine, the app asks whether to go there instead of
jumping. A bookmark you remove stays removed even if an older copy of
the sidecar comes back.

A folder the app cannot write to (a read-only share, a locked SD card)
still works: everything stays in the app's own database, and the reader
says so once. To get sidecars for those books, use **Export sidecars**
(the folder-arrow button in the library's top bar): it writes every
book's sidecar under a folder you pick, laid out like your library, so
you can copy that tree over your comics later.

```sh
sqlite3 'Daredevil 181.cbz.crdb' 'select page, kind, x, y, w, h from panels'
```

## Android phone

ComicRedr is sideloaded as an APK; there is no app store build. You build
it on the Fedora laptop and install it over USB.

### 1. Install the Android SDK

Flutter from step 1 above, plus a JDK and Google's command-line tools:

```sh
sudo dnf install java-21-openjdk-devel android-tools
mkdir -p ~/Android/Sdk/cmdline-tools && cd ~/Android/Sdk/cmdline-tools
curl -LO https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip commandlinetools-linux-*_latest.zip && mv cmdline-tools latest
export ANDROID_HOME=~/Android/Sdk   # put this in ~/.bashrc too
~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager "platform-tools"
flutter config --android-sdk ~/Android/Sdk
flutter doctor --android-licenses
```

The first APK build downloads the rest (the SDK platform, build tools and
the NDK) by itself.

### 2. Create the release key, once

```sh
make keystore
```

This makes `~/.config/comicredr/release.jks` and writes its random
password to `android/key.properties`, which git ignores. **Back up both
files.** Android installs an update over the old app, keeping your
library, positions and bookmarks, only when it is signed with the same
key; with a new key you have to uninstall first and lose that data. On a
new laptop, restore both files instead of running `make keystore` again
(`KEYSTORE=/path/to/release.jks` if you keep it elsewhere, and fix the
path in `android/key.properties`).

### 3. Build and install

Turn on **USB debugging** on the phone (Settings, About phone, tap
**Build number** seven times, then Settings, System, Developer options),
plug it in and accept the laptop's key. Then:

```sh
make apk            # build/app/outputs/flutter-apk/app-release.apk, arm64
make install-apk    # adb install -r, keeps the app's data
make push-model MODEL=other.onnx   # optional: override the built-in model, step 7 above
```

Without a cable, copy the APK to the phone any way you like and open it
in the Files app; Android asks once to allow installing apps from that
source. `APK_ABI=android-arm64,android-x64` adds the emulator's ABI.

### 4. First start

Copy comics to the phone, for example into `Comics` on its storage (with
their `.crdb` sidecars if you want the laptop's panels and positions, see
step 9 above). In the app tap the folder button, allow **All files
access** on the settings page it opens, come back, tap the folder button
again and add `/storage/emulated/0/Comics`. Touch works as in step 8,
with the buttons on the reader's status line for guided view, balloons
and bookmarks; a Bluetooth keyboard gets the same keys as the laptop.
Back steps out of guided view, then the book, then the series, and only
then leaves the app.

The APK has been tested on an Android 14 emulator (x86_64, software
emulation, no model): All-files access, the library scan over CBZ, PDF
and a folder of pages, reading, guided view, taps and swipes, bookmarks,
sidecars, resume and an update install keeping the library. Not yet
tried on a real phone: the ONNX model (the emulator build has no x86_64
ONNX Runtime), pinch zoom, and speed and memory on real hardware.

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
make version                     # the version in pubspec.yaml; bump lib/src/version.dart and CHANGELOG.md with it
make icons                       # re-render linux/packaging/icons/*.png after editing the SVG
(cd packages/comic_analysis && dart run tool/detect_pgm.dart page.pgm)  # Dart detector on one page, to compare with spike/detect_cv.py
tool/e2e_linux.sh [book.cbz|book.pdf|folder]  # release build under Xvfb, driven by real keys incl. guided view and by injected GTK touches, screenshots in build/e2e/
COMICREDR_MODEL=model.onnx tool/e2e_modern.sh  # guided view on real modern comics from test/corpus-modern, screenshots in build/e2e-modern/
tool/e2e_library.sh           # library over the fetched corpus: scan, covers, series, search, ] [, bookmarks, live folder changes, restart, phone layout and touch; checks the index with sqlite3
COMICREDR_MODEL=comicredr-panels.onnx tool/e2e_sidecar.sh a.cbz b.pdf folder/  # two installs as laptop and phone: sidecar written, copied and renamed, re-linked, resumed without detecting, position offered back; plus a read-only shelf
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
(0 of 9, nothing like it in training), and pages whose slanted panels'
boxes overlap too much for the gate.
