# Training the panel detector

Everything needed to train the detector built into ComicRedr again is in
this repository: the lists of comics and where to download them, the
labels drawn on their pages, the scripts, and the settings of the shipped
run. Only the comics themselves are downloaded, because they are not ours
to commit. This page is the whole recipe.

## What the shipped model is

| | |
|---|---|
| File | `assets/models/comicredr-panels.onnx` (43 MB) |
| Architecture | D-FINE-S, Apache-2.0, through Hugging Face transformers |
| Starting weights | `ustc-community/dfine-small-coco` (COCO only) |
| Classes | 0 frame (panel), 1 caption, 2 balloon |
| Real pages | 998 labelled pages from the books in `test/train.manifest.toml` |
| Synthetic pages | 400, from `spike/synth_modern.py --seed 1` |
| Training | 30 epochs at 640 px, batch 4, AdamW lr 1e-4, the last epoch exported |
| Export | ONNX opset 17, input `images` [1, 3, 800, 800], output `output0` [1, 300, 6], folded with onnxslim |
| Time | about 11 minutes an epoch, so 5 to 6 hours, on 4 CPU cores; no GPU needed |
| Python packages | `spike/requirements-train.txt` (Python 3.11) |

The app reads `output0` rows as x0, y0, x1, y1 in input pixels, then a
score and a class. It keeps frames scoring at least 0.3 and balloons at
least 0.4. The model's own name list travels in the ONNX metadata.

## Retrain it

You need Python 3.11 or later, about 7 GB of free disk, and network
access to archive.org, peppercarrot.com (the comics) and huggingface.co
(the starting weights).

```sh
python3 -m pip install --user -r spike/requirements-train.txt
make train-model EPOCHS=1    # optional: the whole pipeline once, in about half an hour
make train-model             # the real run, several hours
make && make install         # build and install the app with the new model
```

`make train-model` runs `tool/train_model.sh`, which does this:

1. Fetches every book in `test/train.manifest.toml` into
   `test/corpus-train/`. It checks each file's sha256 and retries
   archive.org when it answers 500.
2. Extracts the labelled pages into `spike/train_pages/` and copies the
   committed labels from `spike/labels/train/` beside them.
3. Makes 400 synthetic modern pages into `spike/synth_pages/` (see below).
4. Trains `spike/train.py` on both folders for `EPOCHS` epochs at `IMGSZ`
   px. The checkpoints go in `spike/out/train/last/` and `best/`.
5. Exports `last/` to `spike/out/comicredr-panels.onnx`.

Then `tool/fetch_model.sh` checks that ONNX Runtime can load the file and
that it gives [1, 300, 6] rows, and puts it in `assets/models/`. The
downloads, pages and checkpoints are git-ignored. Commit the new
`assets/models/comicredr-panels.onnx` when you want the app to ship it.

The run is seeded, so the same packages on the same machine give the same
model. Different CPUs or package versions can move the numbers a little.

## What may be trained on

A model trained on a comic carries that comic's licence terms, so the
published model learns only from books whose licence allows it:

- public domain (golden- and silver-age books whose copyright was never
  renewed, and US federal government works)
- CC0, or the Public Domain Mark, set by the author
- CC BY, any version

Every such book is listed in `test/train.manifest.toml` with its licence
and where the evidence is, and it is credited in `NOTICE`.

Non-commercial, no-derivatives and share-alike books, and books whose
licence is not certain, are listed in `test/train-local.manifest.toml`
instead, with labels in `spike/labels/train-local/`.
`make train-model LOCAL=1` adds them for a model you keep at home. That
model goes to `spike/out/local/comicredr-panels.onnx`, never to
`assets/`. Use it with `make install-model MODEL=...` and then
`make install KEEP_MODEL=1`, because a plain `make install` goes back to
the built-in model.

The code and weights must stay clean too. That means no Ultralytics (AGPL,
trained models included), no Objects365 checkpoints (academic use only),
and nothing trained on Manga109.

## Adding books and labels

1. Find a comic under an allowed licence and add a `[[book]]` entry to
   `test/train.manifest.toml`. Give it `name` (style folder and file name),
   `style`, `url`, `licence` (the licence and where it says so),
   `purpose` and `sha256`. Copy the layout of the entries already there.
2. Fetch and extract it:
   `python3 spike/fetch_corpus.py --manifest test/train.manifest.toml --out test/corpus-train`,
   then `spike/extract_pages.py` with `--per-book 400 --manifest test/train.manifest.toml`.
3. Label the pages as `spike/LABELLING.md` describes. Use `labelkit.py
   candidates PAGES --weights assets/models/comicredr-panels.onnx` to get
   suggestions from the current model, then `show`, `set` and `check` per
   page. Frames, captions and speech or thought balloons are separate
   classes. A slanted or round panel gets the axis-aligned box around its
   whole frame.
4. `python3 spike/labelkit.py export spike/train_pages spike/labels/train`
   copies the labels into the committed folder.
   Commit them with the manifest entry, and credit the book in `NOTICE`.
5. Never label pages from the test books (below). A model scored on pages
   it learned from looks better than it is.

## Synthetic pages

`spike/synth_modern.py` cuts art out of the labelled frames of the
training pages and lays it out again the way modern comics do. It makes
grids that touch without gutters, slanted gutters and wedge-shaped panels,
panels on black with square or rounded corners, rounded and round frames,
thin-lined panels tilted a few degrees, and panels running off the page
edge. The frame labels are exact. Balloons that come with the art keep
their labels, and a placement that would cut one in half is tried
elsewhere. Only art from the allowed books is used, so the licence rules
above cover these pages too.

On the modern test pages they took the model from 43 to 47 of 66 guided
right. It's worth trying more of them, other layouts, or another mix with
the real pages (`--count`, `--seed`).

## Scoring a model

Three labelled test sets score models and are never trained on:

| Set | Manifest | Labels | Pages |
|---|---|---|---|
| Original | `test/corpus.manifest.toml` | `spike/labels/eval/` | 100 |
| Modern | `test/modern.manifest.toml` | `spike/labels/modern/` | 66 |
| Diagonal | `test/diagonal-eval.manifest.toml` | `spike/labels/diagonal-eval/` | 24 |

```sh
python3 spike/fetch_corpus.py --out test/corpus
python3 spike/fetch_corpus.py --manifest test/modern.manifest.toml --out test/corpus-modern
python3 spike/fetch_corpus.py --manifest test/diagonal-eval.manifest.toml --out test/corpus-diagonal-eval
python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 400
python3 spike/extract_pages.py test/corpus-modern spike/modern_pages --per-book 400 --manifest test/modern.manifest.toml
python3 spike/extract_pages.py test/corpus-diagonal-eval spike/diagonal_pages --per-book 400 --manifest test/diagonal-eval.manifest.toml
python3 spike/labelkit.py import spike/labels/eval spike/eval_pages
python3 spike/labelkit.py import spike/labels/modern spike/modern_pages
python3 spike/labelkit.py import spike/labels/diagonal-eval spike/diagonal_pages
cd spike
for s in eval modern diagonal; do
  python3 evaluate.py ${s}_pages --out out/score-$s --no-cv --trim --trained out/comicredr-panels.onnx
done                                                # out/score-*/report.md
```

`evaluate.py` does what the app does: it trims wide scanned margins, finds
slanted frames' outlines and applies the same confidence gate. For each
page it says whether guided view would move the camera right, show the
page whole, or move it wrong. It also gives panel and balloon F1 at IoU
0.5 and how often balloon mode would stop on a caption. A wrong camera
move is worse than showing a page whole.

The shipped model, and the ones it was chosen over (guided right / whole /
wrong):

| Model | Original 100 | Modern 66 | Diagonal 24 |
|---|---|---|---|
| Old YOLO26s, Manga109 start (not publishable) | 67 / 20 / 13 | 48 / 15 / 3 | 6 / 9 / 9 |
| D-FINE-S, 998 real pages | 69 / 22 / 9 | 43 / 21 / 2 | 6 / 13 / 5 |
| D-FINE-S, 998 real + 400 synthetic (shipped) | 73 / 17 / 10 | 47 / 15 / 4 | 4 / 15 / 5 |

A new model should beat these on the same sets before it replaces the
built-in one. AGENTS.md ("Train the detector") has the longer history.

## Shipping a new model

1. `make train-model`, or `make model MODEL=file.onnx` for a file you
   trained another way.
2. Score it as above and compare.
3. `make && make install`, then open a few books in guided view. Every
   book's panels are detected again the first time it opens, because the
   model file's hash is part of the stored detector version.
4. Run `tool/e2e_modern.sh` and `tool/e2e_margins.sh` on the release build.
5. Commit the model, update the numbers here and in the CHANGELOG, and
   add any new books to `NOTICE`.
