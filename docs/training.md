# Training the panel detector

Everything needed to train the detector built into ComicRedr again is in
this repository: the lists of comics and where to download them, the
labels drawn on their pages, the scripts, and the settings of the shipped
run. Only the comics themselves are downloaded, because they are not ours
to commit. This page is the whole recipe. Extra pages made from comics
of your own, and the notes of every run so far, are in
[comicredr-training-assets](https://github.com/snonux/comicredr-training-assets)
(its TRAINING.md), checked out beside this repository.

## Which model to train, and how

There is one model to train for the app: D-FINE-S, started from its COCO
weights and trained for 30 epochs on the clean books' labelled pages and
the synthetic pages made from them. That is how the shipped model was
made, and `make train-model` does exactly that. The other kinds of run
are tests, or models for your own use:

| You want | Command | What it trains | Can it ship? |
|---|---|---|---|
| A new built-in model | `make train-model` | the shipped recipe: from COCO, 30 epochs at 1e-4, clean books only | yes, when it beats the shipped model |
| A quick answer whether new pages or labels help | `make train-model FROM=shipped` | 8 epochs at 3e-5 on top of the shipped model, old pages and new | no: if they help, train fresh with them |
| A model for yourself, with books that may not be published | `make train-model LOCAL=1`, or `LOCAL=more` for the extra pages alone; `FROM=shipped` makes either a quick run | the clean books plus the NC/ND/SA books and the extra pages of comicredr-training-assets | never |

Every run ends by scoring itself against the shipped model on the three
test sets, into `$CHECKPOINTS/$RUN/scores/summary.md`, and is kept so
that another run can start from it ("Runs and checkpoints"). "Comparing
models" below says how to read the scores and when a model is better.

Only a fresh run ships, because training on top changes the numbers by
itself. On 2026-10-10, 8 epochs on top of the shipped model with no new
pages at all made 4 more wrong camera moves on the original set and 2
more on the modern one. So judge an on-top run with new pages against
an on-top run without them (the control: the same command with no new
pages, or the kept run `2026-10-10-on-top-control`), not only against
the shipped model. When the new pages win there, put them in a fresh run
and compare that with the shipped model.

## How the shipped model was trained

On 2026-09-26, with the recipe `make train-model` runs by default:

| | |
|---|---|
| Command that reproduces it | `make train-model` (`EPOCHS=30`, `LR=1e-4`, `IMGSZ=640`, no `FROM`, no `LOCAL`) |
| File | `assets/models/comicredr-panels.onnx` (43 MB) |
| Architecture | D-FINE-S, Apache-2.0, through Hugging Face transformers |
| Starting weights | `ustc-community/dfine-small-coco` (COCO only) |
| Classes | 0 frame (panel), 1 caption, 2 balloon |
| Real pages | 998 labelled pages from the comics in `test/train.manifest.toml`, labels in `spike/labels/train/` |
| Synthetic pages | 400, from `spike/synth_modern.py --seed 1` |
| Training | 30 epochs at 640 px, batch 4, AdamW at 1e-4 (half that for the backbone), 200 warm-up steps then a cosine down to 5%, weights averaged (EMA 0.998); a tenth of the pages held out for the validation loss |
| Exported | the last epoch, not the one with the lowest validation loss: it guided more test pages right |
| Export | ONNX opset 17, input `images` [1, 3, 800, 800], output `output0` [1, 300, 6], folded with onnxslim |
| Scores | guided right / whole / wrong 73 / 17 / 10 (original), 47 / 15 / 4 (modern), 4 / 15 / 5 (diagonal); panel F1 0.903, 0.894, 0.910; balloon F1 0.787, 0.863, 0.944 |
| Time | about 11 minutes an epoch then, 5 to 6 hours; 16 minutes an epoch in a 4-core cloud container on 2026-10-10, so allow 8 hours; no GPU |
| Checkpoint | not kept; `FROM=shipped` rebuilds one from the ONNX file ("Runs and checkpoints") |
| Python packages | `spike/requirements-train.txt` (Python 3.11; 3.13 works too) |

The app reads `output0` rows as x0, y0, x1, y1 in input pixels, then a
score and a class. It keeps frames scoring at least 0.3 and balloons at
least 0.4. The model's own name list travels in the ONNX metadata.

## Running a training

You need Python 3.11 or later, about 7 GB of free disk, and network
access to archive.org, peppercarrot.com (the comics) and huggingface.co
(the starting weights).

```sh
# CPU-only torch first: without the index URL pip also fetches some 3 GB of CUDA libraries
python3 -m pip install --user torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu
python3 -m pip install --user -r spike/requirements-train.txt
make train-model EPOCHS=1 SCORE=0   # optional: the whole pipeline once, in about half an hour
make train-model                    # the shipped recipe, from COCO: 5 to 8 hours
make train-model FROM=shipped       # or a quick test on top of the shipped model: about 2 hours
make && make install                # build and install the app with the model in assets/models/
```

`make train-model` runs `tool/train_model.sh`, the one way models are
trained. It does this:

1. Fetches every book in `test/train.manifest.toml` into
   `test/corpus-train/`. It checks each file's sha256 and retries
   archive.org when it answers 500.
2. Extracts the labelled pages into `spike/train_pages/` and copies the
   committed labels from `spike/labels/train/` beside them.
3. Makes 400 synthetic modern pages into `spike/synth_pages/` (see below).
4. Trains `spike/train.py` on those folders for `EPOCHS` epochs at
   `IMGSZ` px and learning rate `LR`, starting from COCO or from `FROM`.
   The run is kept as described under "Runs and checkpoints".
5. Exports `last/` to ONNX, in the run's folder and in
   `spike/out/comicredr-panels.onnx` (`spike/out/local/` with `LOCAL`).
6. Scores it against the shipped model (`tool/score_model.sh`, see
   "Comparing models"); `SCORE=0` skips that.

After a fresh run without `LOCAL`, `tool/fetch_model.sh` checks that ONNX
Runtime can load the file and that it gives [1, 300, 6] rows, and puts
it in `assets/models/` in place of the shipped one. Commit it only when
it beats the shipped model ("Shipping a new model"); until then
`FROM=shipped` and the scores go by that file as it is (the script says
so), and `git checkout -- assets/models/comicredr-panels.onnx` puts the
shipped one back. A run with `FROM` or `LOCAL` leaves `assets/models/`
alone: `make install-model MODEL=spike/out/comicredr-panels.onnx` (or
`spike/out/local/...`) tries its model in the app. The downloads, pages
and checkpoints are git-ignored.

The run is seeded, so the same packages on the same machine give the same
model. Different CPUs or package versions can move the numbers a little.

## Runs and checkpoints

Every run is kept, so the next one can start where it ended. A run is a
folder `$CHECKPOINTS/$RUN`:

| | |
|---|---|
| `CHECKPOINTS` | `../comicredr-training-assets/checkpoints/` when that repository is checked out beside this one (git-ignored there), else `spike/out/checkpoints/` |
| `RUN` | `DATE-fresh` or `DATE-on-top`, plus `-local` for `LOCAL=1` and `-local-more` for `LOCAL=more`; or a name of your own |
| `last/`, `best/` | Hugging Face checkpoints of the last epoch and of the lowest validation loss; `FROM=` takes either |
| `start/` | for `FROM=shipped`: the checkpoint rebuilt from the ONNX file the run started from |
| `state.pt` | model, optimiser, schedule and EMA after the last finished epoch |
| `run.json` | the page folders and counts, the command, the starting weights, and the losses and minutes of every epoch |
| `comicredr-panels.onnx` | the exported model |
| `scores/` | `summary.md` (the shipped model against this one) and evaluate.py's report per set |

`spike/train.py` writes all of it after every epoch (`--copy-to`). Start
a run again with the same `RUN` and it goes on from the epoch after the
last one finished, also on another machine when the folder came along; a
killed run loses one epoch at most.

To train on top of an earlier run: `make train-model FROM=$CHECKPOINTS/NAME/last`.
`FROM=shipped` (or `FROM=file.onnx`) starts from a model file instead:
`spike/onnx_to_checkpoint.py` turns the ONNX file back into a checkpoint,
so no run is lost for good as long as its model is. The export keeps every
weight the model uses to find panels, folded (batch norms into the
convolutions before them); the script finds where each weight went by
exporting the same architecture with marked weights, puts them back, and
checks that exporting the result gives the same file. Two small parts the
export drops are made up and settle in training's first steps: the class
and quality heads of decoder layers 0 and 1, which only the training
losses read (copied from layer 2), and the denoising label embedding (as
the COCO start has it). For the shipped model the rebuilt checkpoint
exports to within 1.2e-7 of the file.

On top of a model, 8 epochs at 3e-5 (`FROM`'s defaults) is a third of the
rate and a quarter of the epochs of a fresh run, so that it learns new
pages without unlearning old ones. `EPOCHS=` and `LR=` change them.
The old data must always be in the run: training on new pages alone makes
the model forget what they lack.

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

## Fake pages from your own comics

More frame layouts, with exact labels, come from a repository of their
own: [comicredr-training-assets](https://github.com/snonux/comicredr-training-assets),
checked out beside this one. Its scripts read the frame borders off the
pages of comics you own, keep the gutters and border lines, and replace
the art inside every frame with made-up art, so the pages hold layouts
and no art. Its README has the method, the numbers and the commands.

These pages add to the training set; they replace nothing. Use the
real-art version, `moredata-art/`, which that repository's `real_art.py`
makes in a few minutes from its `moredata/` and this repository's
training pages; `moredata/` itself made the model worse (below).
`LOCAL=1` and `LOCAL=more` add the folder `MORE` names
(`../comicredr-training-assets/moredata` unless you say otherwise):

```sh
T=../comicredr-training-assets
COMICREDR=$PWD python3 $T/real_art.py $T/moredata spike/train_pages $T/moredata-art   # after a first make train-model
make train-model LOCAL=more FROM=shipped MORE=$T/moredata-art   # a quick test on top; compare with the control
make train-model LOCAL=more MORE=$T/moredata-art                # fresh from COCO: the model to keep at home
make train-model LOCAL=1 MORE=$T/moredata-art                   # the same with the train-local books too
```

They go with the model kept at home (`LOCAL=1` or `LOCAL=more`), because
the layouts come from books that are not in `test/train.manifest.toml`.
`moredata/` holds no balloons and no captions; `moredata-art/` holds the
ones that came with the art.

What they did (2026-10-10, 8 epochs on top of the shipped model at 3e-5;
guided right / whole / wrong):

| Model | Original 100 | Modern 66 | Diagonal 24 |
|---|---|---|---|
| Shipped | 73 / 17 / 10 | 47 / 15 / 4 | 4 / 15 / 5 |
| On top, no new pages | 70 / 16 / 14 | 49 / 11 / 6 | 5 / 14 / 5 |
| On top, + `moredata/` | 72 / 16 / 12 | 39 / 20 / 7 | 4 / 15 / 5 |
| On top, + `moredata-art/` | 70 / 17 / 13 | 50 / 9 / 7 | 5 / 12 / 7 |

None beat the shipped model, which stays. The made-up art taught the
model that a panel ends where the colours change, so it joined real
neighbours across thin gutters, and 54 of the pages label two panels as
one frame. The repository's `real_art.py` fixes both: the same layouts
filled with art cut from this repository's clean training pages
(`moredata-art/`, `MORE=../comicredr-training-assets/moredata-art`). That
undid the damage and added nothing over training on top with no new
pages, which itself makes a few more wrong moves on the original set.
The repository's TRAINING.md has the full table (panel and balloon F1)
and the runs; they are kept, see "Runs and checkpoints".

## Comparing models

Three labelled test sets score models and are never trained on:

| Set | Manifest | Labels | Pages |
|---|---|---|---|
| Original | `test/corpus.manifest.toml` | `spike/labels/eval/` | 100 |
| Modern | `test/modern.manifest.toml` | `spike/labels/modern/` | 66 |
| Diagonal | `test/diagonal-eval.manifest.toml` | `spike/labels/diagonal-eval/` | 24 |

Every `make train-model` run scores itself against the shipped model
(`$CHECKPOINTS/$RUN/scores/summary.md`). To compare any models:

```sh
make score-model MODEL=path/to/comicredr-panels.onnx     # the shipped model against it, into spike/out/score/
tool/score_model.sh OUT shipped=assets/models/comicredr-panels.onnx \
    a=$CHECKPOINTS/RUN_A/comicredr-panels.onnx b=$CHECKPOINTS/RUN_B/comicredr-panels.onnx
OVERLAYS=1 tool/score_model.sh OUT ...                    # also draws every page's boxes
```

The first time, it fetches the three sets' comics, extracts their pages
into `spike/eval_pages/`, `spike/modern_pages/` and
`spike/diagonal_pages/` and copies the labels beside them. Then it runs
`spike/evaluate.py PAGES --no-cv --trim --trained MODEL` for every model
and set, one after the other on the same machine, so the times compare,
and writes `OUT/summary.md`. It has a row per model and set:

| Column | What it says |
|---|---|
| Right / whole / wrong | what guided view would do on each page: move the camera right, show the page whole (the confidence gate refused the frames), or move it wrong |
| Panel F1 | how well the frames found match the labelled ones, at IoU 0.5 |
| Balloon F1 | the same for speech and thought balloons |
| Balloon stops on captions | how often balloon mode (`b`) would stop on a caption; fewer is better |
| ms/page | the model alone in ONNX Runtime on this machine |

Under the table are the files' sizes and "Pages that changed": every
page whose outcome differs from the first model's, like
`modern-indie/ihow-000_pdf__p004.jpg whole -> wrong`. With `OVERLAYS=1`,
`OUT/NAME-SET/overlays/` has each page with the labels in grey and the
model's boxes over them, to look at those pages. Each set's full report,
per style too, is in `OUT/NAME-SET/report.md`.

A model is better than the shipped one when, scored on the same machine:

1. it makes no more wrong camera moves on any of the three sets (a wrong
   move is worse than showing a page whole);
2. it guides more pages right over the three sets together;
3. its balloon F1 is no more than 0.01 lower on any set, and balloon mode
   stops on captions no more often; and
4. it is about as fast (the same architecture is the same size, so it
   should be).

The sets are small (24 diagonal pages), so a page or two either way is
noise: look at the pages that changed before believing a gain that
small, and never tune settings or labels to the test sets. For example,
the 2026-10-10 run on top with `moredata/` fails the first rule on the
original and modern sets (12 wrong for 10, 7 for 4), whatever it gains
elsewhere.

`evaluate.py` does what the app does: it trims wide scanned margins, finds
slanted frames' outlines and applies the same confidence gate, so its
right / whole / wrong is what a reader would see.

The shipped model, and the ones it was chosen over (guided right / whole /
wrong):

| Model | Original 100 | Modern 66 | Diagonal 24 |
|---|---|---|---|
| Old YOLO26s, Manga109 start (not publishable) | 67 / 20 / 13 | 48 / 15 / 3 | 6 / 9 / 9 |
| D-FINE-S, 998 real pages | 69 / 22 / 9 | 43 / 21 / 2 | 6 / 13 / 5 |
| D-FINE-S, 998 real + 400 synthetic (shipped) | 73 / 17 / 10 | 47 / 15 / 4 | 4 / 15 / 5 |

The runs since are under "Fake pages from your own comics";
AGENTS.md ("Train the detector") has the older history.

## Shipping a new model

1. Train it fresh with `make train-model`, with any new clean books and
   labels in it. A run with `FROM` is a test and a run with `LOCAL` is
   kept at home; neither ships.
   `make model MODEL=file.onnx` puts a file trained elsewhere in place.
2. Check its `scores/summary.md` against the rules in "Comparing models".
3. `make && make install`, then open a few books in guided view. Every
   book's panels are detected again the first time it opens, because the
   model file's hash is part of the stored detector version.
4. Run `tool/e2e_modern.sh` and `tool/e2e_margins.sh` on the release build.
5. Commit the model, update "How the shipped model was trained" and the
   numbers here and in the CHANGELOG, and add any new books to `NOTICE`.
