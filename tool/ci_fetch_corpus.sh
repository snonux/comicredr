#!/usr/bin/env bash
# Fetches the free test comics the e2e scripts read (test/corpus,
# test/corpus-formats, test/corpus-modern), retrying the ones that fail:
# archive.org answers 500 now and then, and a retry fetches only what is
# missing. CI caches the result keyed on the manifests.
#
#   tool/ci_fetch_corpus.sh
#
# Needs python3 (3.11 or later, for tomllib) and the network (archive.org,
# peppercarrot.com, gutenberg.org).
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() {
  for try in 1 2 3 4; do
    python3 spike/fetch_corpus.py "$@" && return 0
    [[ $try == 4 ]] && { echo "Could not fetch everything in $*"; return 1; }
    echo "Retrying the ones that failed in $((try * 30)) s"; sleep $((try * 30))
  done
}

fetch --manifest test/corpus.manifest.toml --out test/corpus
fetch --manifest test/formats.manifest.toml --out test/corpus-formats
fetch --manifest test/modern.manifest.toml --out test/corpus-modern
du -sh test/corpus test/corpus-formats test/corpus-modern
