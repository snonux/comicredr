# Labelling panels and balloons

The M5 eval set and training set are labelled with `spike/labelkit.py`.
Labels are small JSON files, one per page, written beside the page image
(`<page>.json`) and copied into `spike/labels/` for committing with
`labelkit.py export`; the pages themselves are fetched and extracted, never
committed.

## Per page

```sh
python3 spike/labelkit.py show  PAGE --out /tmp/show.jpg    # candidates over a % grid
python3 spike/labelkit.py set   PAGE --panels "..." --balloons "..."
python3 spike/labelkit.py check PAGE --out /tmp/check.jpg   # the saved label, drawn
```

`show` puts two copies of the page side by side, both with a grid in percent
of the page (thick red lines every 10%, thin every 5%):

- left: panel candidates. `C1..` (green, thick) from classic CV, `F1..`
  (blue, thin) from the pretrained model.
- right: balloon candidates. `B1..` (purple) model balloons, `T1..` (orange)
  model text boxes, which on western pages are often the caption or the text
  inside a balloon.

Candidates are suggestions. A SPEC is a comma-separated list, in reading
order: use a candidate when it is right (`C3`), merge several (`F1+F2`), or
type the box as `x0 y0 x1 y1` in percent (`12 11.5 36 16.5`).
Typed panel edges snap to the nearest gutter within 1.5% of the page and
typed balloons snap to the light region under them, so reading the grid to
about 1% is enough. `!12 11.5 36 16.5` keeps a box exactly as typed, for when
snapping picks the wrong edge. After `set`, always look at `check` and fix
anything off by more than about 2% of the page.

## What to label

**Panel**: one frame of story art, border included.

- Order: western reading order, the order a reader's eye takes: rows top to
  bottom, left to right within a row; a tall panel spanning rows comes before
  the panels to its right.
- A splash page or a full-page picture is one panel.
- Borderless art: the box of the art. Where two borderless panels touch,
  split where the image changes.
- A caption bar sitting on a panel's edge belongs to that panel.
- Page titles, logos and page numbers outside the frames are not panels.
- Covers, text-only pages, letters pages and ads without comic panels get
  **no panels** (empty `--panels ""`). An ad that is itself a comic strip
  gets its panels.
- Inset panels (a small frame on top of a bigger one) are separate panels.

**Balloon**: something the reader reads, in reading order across the page.

- Speech, thought and whisper balloons, and narration captions (the
  rectangular boxes, often yellow).
- Tight box around the balloon's outline, tail excluded. A balloon with no
  outline (floating text) gets the box of its text.
- Two balloons joined by a narrow neck are two balloons.
- Not balloons: sound effects, signs, lettering that is part of the art,
  titles and credits, page numbers, ad copy.

Borderline cases: pick what a guided-view reader would want to step to, and
be consistent.
