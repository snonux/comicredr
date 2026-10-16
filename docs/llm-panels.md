# Panels from a large AI model

How a large vision model (Claude, Codex, ...) can draw a comic's panels
and balloons instead of the built-in detector, what the 2026-10-10 test
found, and how to run the comparison again. Using it on a comic is in
the usage guide: [Panels from a large AI model](guide/05-guided-view.md#panels-from-a-large-ai-model).
The internals are in [AGENTS.md](../AGENTS.md) ("Panels from a large
model"); training the built-in detector is [training.md](training.md).

The built-in detector stays the default: it runs on the phone, offline,
in 0.15 s a page. A large model is an optional extra for the comics
where it falls short, done once on a computer and kept in the comic's
sidecar.

## How it works

A coding agent (Claude Code, Codex) opened in the checkout does the
whole library by following the runbook at the top of
[AGENTS.md](../AGENTS.md), "Drawing the library's panels with a large
model": list the comics, ask the person which to do, then draw them ten
pages at a time. `tool/llm_panels.py` has four commands:

```sh
python3 tool/llm_panels.py library [FOLDER|BOOK ...] [--todo]   # the comics and their pages done
python3 tool/llm_panels.py pages  BOOK WORK [--batch 10]        # WORK/page-NNN.jpg ... and WORK/PROMPT.md
python3 tool/llm_panels.py check  BOOK WORK                     # WORK/panels.json drawn into WORK/check/
python3 tool/llm_panels.py import BOOK WORK/panels.json --harness "Claude Code" --model claude-opus-5-5
```

1. `library` finds the comics as the app's library does (comic files by
   their first bytes, folder books, loose images; dot folders skipped)
   under the app's library folders, read from its index, else under
   `~/Comics`, or under the folders or comics given, and prints pages
   done out of pages for each.
2. `pages` writes each page not done yet (or the first N of them with
   `--batch N`, chosen ones with `--pages`, done ones again with
   `--all`) as a JPEG 1,100 px on its long side with a grid over it, a
   line every 5% labelled every 10%, so the model can read positions off
   the picture, and the prompt (the guide quotes it in full). A page is
   done when the sidecar has imported panels for it, so a stopped run
   goes on where it was.
3. The model, run in WORK with that prompt, writes `panels.json`: per
   page (numbered from 1) the panels in reading order as
   `[x0, y0, x1, y1]` in percent of the page, or `{"outline": [[x, y],
   ...]}` for a slanted panel; balloons (speech, thought, unballooned
   speech); captions kept apart. `"panels": []` shows the page whole.
   It then runs `check` and fixes what does not sit on its edge.
4. `import` writes the rows into the comic's sidecar where the app keeps
   it (beside the comic, or under Settings → Sidecars → In one folder,
   read from the app's index; `--sidecar` names one by hand) as source
   `manual`, model version 1, confidence 1. It also adds the run to the
   record of who drew the comic: an overrides row `panelImport` holding
   `{"runs": [{"harness", "model", "prompt", "pages", "at"}]}` (the last
   20 runs), with `prompt` the tool's `PROMPT_VERSION`. The app keeps,
   merges and exports it like the completed mark, and the comic's
   details (`I`) show it as "Drawn by". The app's `PanelStore.load`
   prefers `manual` over the detector on the pages that have it and
   keeps the given order, so guided view follows the model's reading
   order. Pages left out keep
   the detector's panels. `X` → Redo panels deletes them and the record.

The tool reads CBZ, CBT, PDF (with pypdfium2), folders of pages and
single images in the app's page order, and computes the content key the
app does, both written again in Python; EPUB is not read. A change in
Dart to the sidecar schema, `contentKey`, the page order or `findBooks`
(`packages/comic_formats`), the app's data folder or
`storedSidecarPath` must be made in the tool too.
`tool/e2e/e2e_llm_panels.sh` checks the whole path in the release build.

## Which comics to draw: triage

Drawing a whole library costs a lot, and on most comics the built-in
detector already does well. The comics worth a large model are the ones
whose frames are not straight (curved, slanted, torn, borderless, insets
over a splash page) and whose words are not in obvious balloons
(captions, loose lettering, wordless pages). Asked to "triage comic
panels", an agent follows "Triage: which comics to draw" in
[AGENTS.md](../AGENTS.md):

```sh
python3 tool/triage_panels.py [FOLDER|BOOK ...] [--out /tmp/comicredr-triage] [--samples 8] [--sheets 40]
```

The tool samples 8 pages from the middle of each comic (10% to 90%, so
covers and back matter mostly stay out) and runs the built-in detector
on them exactly as `detector/evaluate.py` does: frames, balloons and
captions, the frames whose outline is not a rectangle
(`detector/outlines.py`), and the confidence gate with its reasons. Its
score rewards pages with two or more frames that are slanted or overlap
(which the gate refuses) and is divided down by the balloons found a
page:

```
story × (slanted + overlapping + ½ refused) / (1 + balloons a page / 3)
```

It writes `ranking.txt` (every comic, best first; comics already drawn
are listed as done) and contact sheets of the best 40 (`sheets/NN.jpg`,
three comics a sheet, eight sampled pages each). The score is only a
lead: cover galleries and pin-up books score high too, with one frame
the gate refuses and no balloons, and have nothing to draw. So the
agent looks at every sheet and sorts the comics into best fits, slanted
frames full of balloons, and near misses, then asks which to draw.

The first triage, 2026-10-16, looked at 196 comics in ~/Comics in about
half an hour on 4 cores. Of the 37 best-ranked, seven were best fits
(366 pages: Enuma 1 and 2, Khulan #1, Aphrodite IX #0, HyperGeist 01,
Vampirella Masters Vol. 6 and An Entity Observes All Things), eleven had
slanted frames but many balloons, and the rest were straight layouts
with balloons, cover galleries or pin-ups. Claude Code drew the seven
with one subagent a comic (a chain of them for the two long books, 30
pages each), each importing as it went.

## Drawn panels and S3

`import` stamps the sidecar's `written_at` with the time of the import,
so a comic synced to S3 has the newer sidecar here and the app never
pulls the bucket's older one over it. Nor does it upload the new one by
itself, since the app did not write it: it goes up the next time the app
writes that sidecar (reading the comic moves the position), with `gu`
on the comic (a sync of its sidecar, the newer one winning), or, with
the app running, by queueing it in the index for the next sync (every 5
minutes):

```sh
sqlite3 ~/Comics/.comicredr/comicredr.sqlite \
  "update s3_books set pending='sidecar', pending_since=strftime('%s','now') where content_key='KEY' and pending is null"
```

The sync compares the two `written_at`s again before it sends anything,
so queueing a comic whose bucket sidecar is newer pulls that one
instead, as for any comic.

## The test, 2026-10-10

Claude (Opus, in a Claude Code session) drew 40 pages of the labelled
test sets the way the tool asks: 14 of the original set, 14 modern and
12 diagonal. 32 of them were picked because the shipped model gets them
wrong or shows them whole, 8 because it gets them right. Its answers
are committed in `detector/llm-boxes/claude-2026-10-10/` and scored by
`detector/evaluate.py --boxes`, the same labels and the same gate, trim and
outlines as the shipped model.

Guided view, right / whole / wrong:

| Set | Pages | Shipped model | Claude, app's reading order | Claude, its own order |
|---|---|---|---|---|
| Original | 14 | 3 / 4 / 7 | 7 / 0 / 7 | 8 / 0 / 6 |
| Modern | 14 | 3 / 7 / 4 | 11 / 0 / 3 | 11 / 0 / 3 |
| Diagonal | 12 | 2 / 6 / 4 | 10 / 0 / 2 | 12 / 0 / 0 |
| All | 40 | 8 / 17 / 15 | 28 / 0 / 12 | 31 / 0 / 9 |

"Its own order" is what a reader sees, since imported panels keep their
order. Claude got all 8 pages right that the model gets right.

Panel and balloon F1 at IoU 0.5, model / Claude:

| Set | Panels | Balloons | Balloon stops on captions |
|---|---|---|---|
| Original | 0.915 / 0.946 | 0.743 / 0.683 | 3 / 2 |
| Modern | 0.854 / 0.982 | 0.800 / 0.994 | 8 / 0 |
| Diagonal | 0.879 / 1.000 | 0.867 / 0.966 | 1 / 0 |

The original set's labels count free-floating speech and some caption
boxes as balloons (barefoot-bride p021 alone has 15), so Claude's lower
balloon score there is mostly that convention.

Where Claude was wrong: all 9 pages are one panel more or fewer than
labelled where what counts as a panel is a judgement call: a text box
or an ad box drawn as a panel (mercy p003, international p032), the
flashback strip on Pepper&Carrot e06 p001, a loose borderless layout
(barefoot p021), I Villain's spreads, First Woman p006, weird p038, an
inset circle (international p028). It never shows a page whole, so a
miss is a wrong camera move.

The labels are no independent truth: they were drawn by Claude
subagents too, by the rules in `detector/LABELLING.md` (M5). So "wrong"
here means Claude disagreed with an earlier Claude. Side by side
(`/mnt/project-files/comicredr-llm-panels/misses/` in the project), the
labels look wrong on international p028 (reading order) and weird p038
(two panels merged), Claude on First Woman p006 (an inset merged) and
on the two ad boxes; the rest are judgement calls. A person has to rule
before a prompt change counts as better.

The run was Opus 5.5 at medium effort, in the Claude Code session that
wrote the tool. Effort is set in Claude Code with `/effort` (or `/model`)
and in Codex with `-c model_reasoning_effort=high`.

Blind redraws (2026-10-13): three fresh Claude sessions that never saw
the labels drew the 40 pages again: the tool's prompt at medium effort,
a sharper prompt (text-only boxes are no panels, an inset is its own
panel, stricter reading order) at medium, and the same at high effort.
All three came out 29 / 3 / 8. Three to four pages flip between runs
(noise); the same nine disagreements came back in every run, so they are
Claude's settled view against the labels, not chance. The sharper prompt
and high effort bought nothing, so the tool keeps its prompt
(`PROMPT_VERSION` 1) and medium effort is enough. The "whole" pages are
the gate refusing a drawing: an inset overlapping its panel, or panels
covering half the page.

Round 2 (2026-10-14, prompt version 2, snonux's rules): snonux looked
at the nine pages and found Claude mostly right; what he did miss was
balloons sticking out of their panel, cut off by the camera. The prompt
now puts comfortable reading first (no panel or line missed, the story's
order), grows a panel to hold its own balloons even across the next
panel, lets the words settle an open order, follows diagonal and
half-diagonal borders with outlines, and gives a big panel and its inset
as two stops when unsure. The app's confidence gate lets imported panels
overlap, since grown frames and insets do. Four fresh sessions, ten pages
each, redrew the 40 pages: 27 / 0 / 13 against the old labels, which is
expected, since the new rules draw differently from them on purpose
(grown frames, insets twice, text boxes kept so no text is missed).
snonux judged the drawings side by side and was happy with them
(`/mnt/project-files/comicredr-llm-panels/round2/` in the project). One
lesson: a single session drawing all 40 pages hit Claude Code's image
limit; ten pages a session did not.

Caveats: one model's judgement on 40 pages, not a blind test. The page
list used to pick them showed the labelled panel counts, and one page's
labels were seen while checking the scoring (its answer was left as it
was). The pages are mostly the model's failures, so this says Claude
fixes most of them, not how it does over a whole book.

Time and cost: about half a minute a page; roughly 1,200 image tokens in
and 0.5 to 1.5 thousand out, 3 to 5 US cents a page at Opus API prices
($4 / $20 per million tokens), $1 to $1.50 for a 30-page comic. Inside a
Claude subscription it counts against usage instead.

## Running the comparison again

With the test sets in place (`make score-model` fetches and extracts
them the first time, see [training.md](training.md#comparing-models)):

```sh
cd detector
for set in eval modern diagonal; do
  python3 evaluate.py ${set}_pages --out out/llm-$set --no-cv --trim \
      --trained ../assets/models/comicredr-panels.onnx \
      --boxes llm-boxes/claude-2026-10-10 --keep-order --overlays
done
```

Only pages with a boxes file are scored, for both detectors. Leave out
`--keep-order` to put the boxes through the app's own reading order
(the middle column above). `out/llm-SET/report.md` has the tables and
`--overlays` draws every page.

To test another model or a newer prompt: make the pages and prompt with
`tool/llm_panels.py pages` from the comic, have the model write
`panels.json`, and turn each page into a boxes file,
`detector/llm-boxes/NAME/<style>/<page stem>.json` (the style and stem of
the page in `detector/*_pages/`), with every box as a share of the page
`[x, y, w, h]`:

```json
{"panels": [[0.05, 0.09, 0.44, 0.21]], "shapes": [null],
 "balloons": [[0.17, 0.55, 0.44, 0.06]], "captions": []}
```

`shapes` gives a slanted panel's outline as `[[x, y], ...]` shares, or
`null` to have it traced as the model's are. Score it as above with
`--boxes llm-boxes/NAME`.
