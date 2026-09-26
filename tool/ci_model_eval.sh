#!/usr/bin/env bash
# Scores the model built into the app on the labelled eval pages, the
# original 100 and the modern 66, and fails when it guides more than 3
# pages fewer right than the shipped model did (AGENTS.md, "Train the
# detector": 73 and 47). Reports land in spike/out/{eval,modern}/.
#
#   tool/ci_fetch_corpus.sh && tool/ci_model_eval.sh
set -euo pipefail
cd "$(dirname "$0")/.."
model=${1:-$PWD/assets/models/comicredr-panels.onnx}

python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 400 >/dev/null
python3 spike/extract_pages.py test/corpus-modern spike/modern_pages --per-book 400 --manifest test/modern.manifest.toml >/dev/null
python3 spike/labelkit.py import spike/labels/eval spike/eval_pages
python3 spike/labelkit.py import spike/labels/modern spike/modern_pages
(cd spike &&
  python3 evaluate.py eval_pages --out out/eval --no-cv --trim --trained "$model" >/dev/null &&
  python3 evaluate.py modern_pages --out out/modern --no-cv --trim --trained "$model" >/dev/null)
cat spike/out/eval/report.md spike/out/modern/report.md
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || cat spike/out/eval/report.md spike/out/modern/report.md >>"$GITHUB_STEP_SUMMARY"
python3 - <<'PY'
import json, sys
failed = False
for name, want in (("eval", 73), ("modern", 47)):
    s = json.load(open(f"spike/out/{name}/results.json"))["summary"]["all"]["trained"]
    ok = s["right"] >= want - 3
    failed |= not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: guided right {s['right']}/{s['pages']} (shipped {want}), "
          f"whole {s['whole']}, wrong {s['wrong']}, panel F1 {s['panel_f1']:.3f}")
sys.exit(1 if failed else 0)
PY
