#!/usr/bin/env bash
# Runs one of the tool/e2e_*.sh scripts the way CI does: on the release
# build already in build/ (E2E_SKIP_BUILD=1) and on the books from the test
# corpus each one was written against. .github/workflows/ci.yml runs every
# name below, one job each; it works the same on a laptop.
#
#   tool/ci_fetch_corpus.sh   # once
#   make && make tarball      # the build the scripts reuse
#   tool/ci_e2e.sh pages
#
# Needs what the scripts need (AGENTS.md, "Cloud container setup").
set -euo pipefail
cd "$(dirname "$0")/.."
export E2E_SKIP_BUILD=1

c=test/corpus
reptisaurus=$c/silver-age/reptisaurus-v2-005.cbz
space_war=$c/silver-age/space-war-002.cbz
all_top=$c/golden-age/all-top-comics-6.cbz
mercy=$c/golden-age/mercy-for-millions.cbz
first_love=$c/golden-age-pdf/first-love-illustrated-078.pdf
pepper=$c/modern/pepper-carrot-e06
i_villain=test/corpus-modern/modern-indie/i-villain.pdf

name=${1:?usage: tool/ci_e2e.sh NAME (a tool/e2e_NAME.sh script, or linux-book)}
case "$name" in
  linux-book)     set -- tool/e2e_linux.sh "$all_top" ;;
  bookmarks)      set -- tool/e2e_bookmarks.sh "$space_war" ;;
  details|pages)  set -- "tool/e2e_$name.sh" "$reptisaurus" "$first_love" ;;
  edit)           set -- tool/e2e_edit.sh "$space_war" "$reptisaurus" "$pepper" ;;
  reset|whole_page|regions|resize)
                  set -- "tool/e2e_$name.sh" "$reptisaurus" ;;
  pause_whole)    set -- tool/e2e_pause_whole.sh "$reptisaurus" 3 ;;
  resume)         set -- tool/e2e_resume.sh "$mercy" ;;
  spreads)        set -- tool/e2e_spreads.sh "$all_top" "$i_villain" ;;
  m9)             set -- tool/e2e_m9.sh "$mercy" ;;
  memory)         set -- tool/e2e_memory.sh "$all_top" ;;
  sidecar)
    # Its read-only shelf is a bind mount, which needs root.
    exec sudo -E env "PATH=$PATH" tool/e2e_sidecar.sh "$reptisaurus" "$first_love" "$pepper" ;;
  margins)
    # It pads labelled eval pages, so it needs them extracted first.
    [[ -d spike/eval_pages ]] || python3 spike/extract_pages.py test/corpus spike/eval_pages --per-book 400 >/dev/null
    set -- tool/e2e_margins.sh ;;
  *)
    [[ -x tool/e2e_$name.sh ]] || { echo "No tool/e2e_$name.sh"; exit 2; }
    set -- "tool/e2e_$name.sh" ;;
esac
echo "+ $*"
exec "$@"
