#!/usr/bin/env bash
# Scores detector models on the three test sets (original 100, modern 66,
# diagonal 24 pages), which nothing is ever trained on, and writes one
# table comparing them: guided right / whole / wrong, panel F1, balloon
# F1, balloon stops on captions, milliseconds a page and the file's size.
# All models are scored on this machine one after the other, so the times
# compare.
#
#   tool/score_model.sh OUT [NAME=]MODEL.onnx [[NAME=]MODEL.onnx ...]
#   tool/score_model.sh spike/out/score shipped=assets/models/comicredr-panels.onnx new=RUN/comicredr-panels.onnx
#
# The first model is the one the others are compared with: the summary
# also lists every page whose outcome differs from its. OVERLAYS=1 draws
# each page's boxes into OUT/NAME-SET/overlays/ to look at those pages.
#
# Fetches and extracts the test sets the first time (archive.org,
# peppercarrot.com). Output: OUT/NAME-SET/report.md (evaluate.py's full
# report, per style too) and OUT/summary.md. docs/training.md, "Comparing
# models", says how to read it.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 2 ]] || { sed -n '2,19p' "$0"; exit 1; }
out="$1"; shift
mkdir -p "$out"
overlays=$([[ "${OVERLAYS:-}" == 1 ]] && echo --overlays || true)

fetch() {
  local wait=30
  for try in 1 2 3 4 5; do
    python3 spike/fetch_corpus.py --manifest "$1" --out "$2" && return 0
    [[ $try == 5 ]] && break
    echo "Retrying the ones that failed in $wait s"; sleep "$wait"; wait=$((wait * 2))
  done
  echo "Some test comics could not be fetched; run this again later: it keeps what it has."
  exit 1
}

# set name, manifest, corpus folder, pages folder, labels folder
sets=(
  "eval test/corpus.manifest.toml test/corpus spike/eval_pages spike/labels/eval"
  "modern test/modern.manifest.toml test/corpus-modern spike/modern_pages spike/labels/modern"
  "diagonal test/diagonal-eval.manifest.toml test/corpus-diagonal-eval spike/diagonal_pages spike/labels/diagonal-eval"
)
for s in "${sets[@]}"; do
  read -r name manifest corpus pages labels <<< "$s"
  want=$(find "$labels" -name '*.json' | wc -l)
  have=$( [[ -d $pages ]] && find "$pages" -name '*.json' ! -name '*.cand.json' | wc -l || echo 0)
  if [[ $have != "$want" ]]; then
    echo "== Preparing the $name test pages"
    fetch "$manifest" "$corpus"
    python3 spike/extract_pages.py "$corpus" "$pages" --per-book 400 --manifest "$manifest"
    find "$pages" -name '*.json' ! -name '*.cand.json' -delete
    python3 spike/labelkit.py import "$labels" "$pages"
  fi
done

names=()
for m in "$@"; do
  if [[ $m == *=* ]]; then n=${m%%=*}; f=${m#*=}; else f=$m; n=$(basename "$(dirname "$f")"); fi
  [[ -f $f ]] || { echo "No model at $f"; exit 1; }
  names+=("$n=$f")
  for s in "${sets[@]}"; do
    read -r name _ _ pages _ <<< "$s"
    echo "== $n on the $name set"
    python3 spike/evaluate.py "$pages" --out "$out/$n-$name" --no-cv --trim --trained "$f" $overlays > "$out/$n-$name.log"
  done
done

python3 - "$out" "${names[@]}" <<'EOF'
import json, os, sys
from pathlib import Path
out, models = Path(sys.argv[1]), [m.split("=", 1) for m in sys.argv[2:]]
sets = [("eval", "Original 100"), ("modern", "Modern 66"), ("diagonal", "Diagonal 24")]
rows = ["| Model | Set | Right / whole / wrong | Panel F1 | Balloon F1 | Balloon stops on captions | ms/page |",
        "|---|---|---|---|---|---|---|"]
for name, _ in models:
    for key, label in sets:
        s = next(iter(json.loads((out / f"{name}-{key}" / "results.json").read_text())["summary"]["all"].values()))
        rows.append(f"| {name} | {label} | {s['right']} / {s['whole']} / {s['wrong']} | {s['panel_f1']:.3f} | "
                    f"{s['balloon_f1']:.3f} | {s['balloon_on_caption']} | {s['ms']:.0f} |")
sizes = [f"- {name}: `{path}`, {os.path.getsize(path) / 1e6:.1f} MB" for name, path in models]


def outcomes(name, key):
    pages = json.loads((out / f"{name}-{key}" / "results.json").read_text())["pages"]
    return {p["page"]: next(iter(p["det"].values()))["outcome"] for p in pages}


changed = []
for name, _ in models[1:]:
    for key, label in sets:
        was, now = outcomes(models[0][0], key), outcomes(name, key)
        diff = [f"{page} {was[page]} -> {now[page]}" for page in sorted(now) if was.get(page) != now[page]]
        changed += [f"{name} against {models[0][0]}, {label}: {len(diff)} page{'' if len(diff) == 1 else 's'}", "",
                    *[f"- {d}" for d in diff], ""]
text = "\n".join(["# Scores", "", "Right / whole / wrong: what guided view would do on each page (a wrong camera",
                  "move is worse than showing the page whole). ms/page: the model alone in ONNX Runtime on",
                  f"this machine ({os.cpu_count()} cores).", "", *rows, "", "Files:", "", *sizes, "",
                  *(["## Pages that changed", "", *changed] if changed else [])]).rstrip() + "\n"
(out / "summary.md").write_text(text)
print(text)
EOF
