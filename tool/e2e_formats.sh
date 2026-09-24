#!/usr/bin/env bash
# End-to-end check of CBT and comic EPUB books on the Linux build, over real
# files from test/formats.manifest.toml (fetched into test/corpus-formats/).
#
# From the public-domain Science Comics 1 CBZ it makes a CBT with GNU tar,
# a second one in POSIX pax format with a folder name too long for a plain
# tar header, and a fixed-layout EPUB 3 with the same page images. Then:
#   - the library indexes them and the calibre-made Dark Sun Chronicles
#     EPUB, and leaves out the Internet Archive's OCR derivative and
#     Alice in Wonderland (checked with sqlite3);
#   - each copy of Science Comics opened from the command line shows the
#     same pixels as the CBZ on page 1, page 3 and the last page;
#   - the refused EPUBs say why on the status line (screenshots).
#
#   python3 spike/fetch_corpus.py --manifest test/formats.manifest.toml --out test/corpus-formats --skip-model
#   tool/e2e_formats.sh [dir]   # default test/corpus-formats
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3, GNU tar, unzip.
# Output: build/e2e-formats/shot_*.png and build/e2e-formats/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-test/corpus-formats}"
out=build/e2e-formats
rm -rf "$out" && mkdir -p "$out/Comics" "$out/Refused" "$out/home" "$out/pages"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

cp "$src/science-comics-001.cbz" "$src/dark-sun-chronicles-1.epub" "$comics/"
cp "$src/science-comics-001-ia.epub" "$src/alice.epub" "$comics/"
unzip -q "$src/science-comics-001.cbz" -d "$out/pages"
# GNU tar, entries in whatever order the file system lists them: the reader
# sorts them.
tar --format=gnu -cf "$comics/science-comics-001.cbt" -C "$out/pages" .
long="$out/pax/$(printf 'a-folder-name-well-past-a-hundred-characters-%.0s' 1 2 3)"
mkdir -p "$long" && cp -r "$out/pages"/. "$long/"
tar --format=posix -cf "$comics/science-comics-001-pax.cbt" -C "$out/pax" .
python3 - "$out/pages" "$comics/science-comics-001-fixed.epub" <<'PY'
import os, sys, zipfile, re
pages_dir, dest = sys.argv[1], sys.argv[2]
def natural(s): return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', s)]
images = sorted((os.path.relpath(os.path.join(r, f), pages_dir) for r, _, fs in os.walk(pages_dir)
                 for f in fs if f.lower().endswith(('.jpg', '.jpeg', '.png'))), key=natural)
with zipfile.ZipFile(dest, 'w') as z:
    z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip')  # Stored, first.
    z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" '
               'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
               '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
               '</rootfiles></container>')
    items, spine = [], []
    for i, name in enumerate(images):
        ext = os.path.splitext(name)[1].lower()
        z.write(os.path.join(pages_dir, name), f'OEBPS/img/{i:03d}{ext}', zipfile.ZIP_STORED)
        z.writestr(f'OEBPS/p{i:03d}.xhtml', '<?xml version="1.0" encoding="UTF-8"?>'
                   '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page</title>'
                   '<meta name="viewport" content="width=1200, height=1700"/></head>'
                   f'<body><div><img src="img/{i:03d}{ext}" alt="Page {i + 1}"/></div></body></html>')
        mt = 'image/png' if ext == '.png' else 'image/jpeg'
        props = ' properties="cover-image"' if i == 0 else ''
        items.append(f'<item id="i{i}" href="img/{i:03d}{ext}" media-type="{mt}"{props}/>'
                     f'<item id="p{i}" href="p{i:03d}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="p{i}"/>')
    z.writestr('OEBPS/content.opf', '<?xml version="1.0" encoding="UTF-8"?>'
               '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
               '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">sc1</dc:identifier>'
               '<dc:title>Science Comics</dc:title><dc:date>1946-01</dc:date><dc:language>en</dc:language>'
               '<meta property="rendition:layout">pre-paginated</meta>'
               '<meta property="belongs-to-collection" id="c">Science Comics</meta>'
               '<meta refines="#c" property="group-position">1</meta></metadata>'
               f'<manifest>{"".join(items)}</manifest><spine>{"".join(spine)}</spine></package>')
print(f'{len(images)} pages')
PY
pages=$(python3 -c 'import zipfile,sys; print(sum(n.lower().endswith((".jpg",".jpeg",".png")) for n in zipfile.ZipFile(sys.argv[1]).namelist()))' "$src/science-comics-001.cbz")
echo "Comics folder:"; ls -l "$comics" | sed 's/^/  /'

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 5
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app" 2>/dev/null; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
sql() { python3 -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall(); print(" ".join("|".join(map(str,x)) for x in r))' "$db" "$1"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# The page area, above the status line whose title differs per file (the
# window is 1280x720, the status line its bottom 55 pixels).
page_of() { convert "$out/shot_$1.png" -crop 1280x660+0+0 +repage "$out/crop_$1.png"; }
same() { # same "what" shotA shotB
  page_of "$2"; page_of "$3"
  local diff
  diff=$(compare -metric AE "$out/crop_$2.png" "$out/crop_$3.png" /dev/null 2>&1 || true)
  check "$1" "$diff pixels differ" "0 pixels differ"
}

# 1. The library: five books in, two refused.
start --add-root "$comics"
for _ in $(seq 1 120); do
  [[ -f "$db" ]] && [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 5 ]] && break
  sleep 0.5
done
sleep 3 # The scan finishes with the refusals; covers land.
key Tab;  shot 01_library_books
check "books indexed" "$(sql 'select count(*) from books')" 5
check "formats" "$(sql 'select format, count(*) from books group by format order by format')" "cbt|2 cbz|1 epub|2"
check "Science Comics pages, every copy" "$(sql "select distinct b.page_count from books b join files f using (content_key) where f.rel_path like 'science-comics-001%'")" "$pages"
check "EPUB metadata" "$(sql "select b.title, b.year from books b join files f using (content_key) where f.rel_path = 'science-comics-001-fixed.epub'")" "Science Comics #1|1946"
check "Dark Sun pages" "$(sql "select b.page_count from books b join files f using (content_key) where f.rel_path = 'dark-sun-chronicles-1.epub'")" 54
check "refused not indexed" "$(sql "select count(*) from files where rel_path in ('alice.epub', 'science-comics-001-ia.epub')")" 0
check "covers" "$(ls "$out"/home/.cache/org.snonux.comicredr/covers/*.jpg 2>/dev/null | wc -l)" 5
python3 -c 'import sqlite3,sys; [print("  ", *r) for r in sqlite3.connect(sys.argv[1]).execute("select f.rel_path, b.format, b.page_count, b.title from books b join files f using (content_key) order by f.rel_path")]' "$db"
key slash; xdotool type --delay 60 "science" 2>/dev/null; sleep 1; shot 02_search_science
stop

# 2. The same pages from the CBZ, both CBTs and the EPUB.
for book in science-comics-001.cbz science-comics-001.cbt science-comics-001-pax.cbt science-comics-001-fixed.epub; do
  tag=${book//[.-]/_}
  start "$comics/$book"
  key g g;   shot "10_${tag}_p1"
  key l l;   shot "11_${tag}_p3"
  key G;     shot "12_${tag}_last"
  stop
done
for book in science_comics_001_cbt science_comics_001_pax_cbt science_comics_001_fixed_epub; do
  for step in 10_%s_p1 11_%s_p3 12_%s_last; do
    same "$book $(printf "$step" '')" "$(printf "$step" science_comics_001_cbz)" "$(printf "$step" "$book")"
  done
done
check "last page saved" "$(sql "select distinct p.page from progress p")" $((pages - 1))

# 3. The calibre EPUB reads page by page; guided view runs on it.
start "$comics/dark-sun-chronicles-1.epub"
shot 20_dark_sun_p1
key l l l; shot 21_dark_sun_p4
key v; sleep 2; key l; shot 22_dark_sun_guided
stop

# 4. Refused books say why.
start "$comics/alice.epub";                  shot 30_alice_refused
stop
start "$comics/science-comics-001-ia.epub";  shot 31_ia_derivative_refused
stop

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
