#!/usr/bin/env bash
# End-to-end check of CBT and comic EPUB books on the Linux build, over real
# files from test/manifests/formats.manifest.toml (fetched into test/corpus-formats/).
#
# From the public-domain Science Comics 1 CBZ it makes a CBT with GNU tar,
# a second one in POSIX pax format with a folder name too long for a plain
# tar header, a fixed-layout EPUB 3 with the same page images, and an SVG
# spine EPUB whose page points at the first image. Then:
#   - the library indexes them and the calibre-made Dark Sun Chronicles
#     EPUB, and leaves out the Internet Archive's OCR derivative and
#     Alice in Wonderland (checked with sqlite3);
#   - each copy of Science Comics opened from the command line shows the
#     same pixels as the CBZ on page 1, page 3 and the last page;
#   - the refused EPUBs say why on the status line (screenshots).
#
#   python3 detector/fetch_corpus.py --manifest test/manifests/formats.manifest.toml --out test/corpus-formats --skip-model
#   tool/e2e/e2e_formats.sh [dir]   # default test/corpus-formats
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick, python3, GNU tar, unzip.
# Output: build/e2e-formats/shot_*.png and build/e2e-formats/contact.png.
set -euo pipefail
cd "$(dirname "$0")/../.."

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
python3 - "$out/pages" "$comics/science-comics-001-fixed.epub" "$comics/science-comics-001-svg.epub" <<'PY'
import os, sys, zipfile, re
pages_dir, dest, svg_dest = sys.argv[1:]
def natural(s): return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', s)]
images = sorted((os.path.relpath(os.path.join(r, f), pages_dir) for r, _, fs in os.walk(pages_dir)
                 for f in fs if f.lower().endswith(('.jpg', '.jpeg', '.png'))), key=natural)
container_xml = ('<?xml version="1.0"?><container version="1.0" '
                 'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                 '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                 '</rootfiles></container>')
with zipfile.ZipFile(dest, 'w') as z:
    z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip')  # Stored, first.
    z.writestr('META-INF/container.xml', container_xml)
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
first = images[0]
ext = os.path.splitext(first)[1].lower()
media_type = 'image/png' if ext == '.png' else 'image/jpeg'
with zipfile.ZipFile(svg_dest, 'w') as z:
    z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip')
    z.writestr('META-INF/container.xml', container_xml)
    z.writestr('OEBPS/content.opf', '<package xmlns="http://www.idpf.org/2007/opf" '
               'version="3.0" unique-identifier="id"><metadata '
               'xmlns:dc="http://purl.org/dc/elements/1.1/">'
               '<dc:identifier id="id">science-comics-svg</dc:identifier>'
               '<dc:title>Science Comics SVG</dc:title><dc:language>en</dc:language>'
               '<meta property="rendition:layout">pre-paginated</meta></metadata><manifest>'
               '<item id="page" href="pages/first.svg" media-type="image/svg+xml"/>'
               f'<item id="art" href="images/first{ext}" media-type="{media_type}"/>'
               '</manifest><spine><itemref idref="page"/></spine></package>')
    z.writestr('OEBPS/pages/first.svg', '<svg xmlns="http://www.w3.org/2000/svg" '
               'xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1200 1700">'
               f'<image xlink:href="../images/first{ext}" width="1200" height="1700"/></svg>')
    z.write(os.path.join(pages_dir, first), f'OEBPS/images/first{ext}', zipfile.ZIP_STORED)
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
# Xvfb takes a moment to listen; the X11 app cannot open it until then.
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

start() {
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    HOME="$PWD/$out/home" GDK_BACKEND=x11 build/linux/x64/release/bundle/comicredr \
    "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 5
  local win=
  for _ in $(seq 1 40); do
    win=$(xdotool search --name '^ComicRedr$' 2>/dev/null | tail -1)
    [[ -n "$win" ]] && break
    sleep 0.25
  done
  if [[ -z "$win" ]]; then
    echo "ComicRedr window did not appear in Xvfb; see $out/app.log" >&2
    return 1
  fi
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
  diff=$(tool/e2e/differ_px.sh 0% "$out/crop_$2.png" "$out/crop_$3.png")
  check "$1" "$diff pixels differ" "0 pixels differ"
}

# 1. The library: six books in, two refused.
start --add-root "$comics"
for _ in $(seq 1 120); do
  [[ -f "$db" ]] && [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 6 ]] && break
  sleep 0.5
done
sleep 3 # The scan finishes with the refusals; covers land.
key Tab; key b; key Return; shot 01_library_books
check "books indexed" "$(sql 'select count(*) from books')" 6
check "formats" "$(sql 'select format, count(*) from books group by format order by format')" "cbt|2 cbz|1 epub|3"
check "Science Comics pages, every full copy" "$(sql "select distinct b.page_count from books b join files f using (content_key) where f.rel_path like 'science-comics-001%' and f.rel_path != 'science-comics-001-svg.epub'")" "$pages"
check "EPUB metadata" "$(sql "select b.title, b.year from books b join files f using (content_key) where f.rel_path = 'science-comics-001-fixed.epub'")" "Science Comics #1|1946"
check "Dark Sun pages" "$(sql "select b.page_count from books b join files f using (content_key) where f.rel_path = 'dark-sun-chronicles-1.epub'")" 54
check "refused not indexed" "$(sql "select count(*) from files where rel_path in ('alice.epub', 'science-comics-001-ia.epub')")" 0
check "SVG spine page count" "$(sql "select b.page_count from books b join files f using (content_key) where f.rel_path = 'science-comics-001-svg.epub'")" 1
check "covers" "$(ls "$out"/home/.cache/org.snonux.comicredr/covers/*.jpg 2>/dev/null | wc -l)" 6
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

start "$comics/science-comics-001-svg.epub"
key g g; shot 13_science_comics_001_svg_p1
stop
same "SVG spine EPUB page 1" 10_science_comics_001_cbz_p1 13_science_comics_001_svg_p1

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
