#!/usr/bin/env bash
# End-to-end check of two-page mode on a book with a scanned double-page
# spread, on the Linux release build under Xvfb.
#
#   tool/e2e_spreads.sh book.cbz [spreads.pdf]
#
# From book.cbz it makes a copy whose fifth and sixth pages are joined into
# one wide image, the way a scanned spread arrives. In two-page mode (`d`)
# it steps through the book with `l`, recording the saved page after each
# step, and fails unless the wide page stands alone and the pages after it
# pair as before (6-7 of the original numbering, then 8-9). It checks the
# page fills the screen's height, not half of it, reopens the book on the
# page after the spread to see the same pair come back, then shows the
# spread in guided view. With spreads.pdf (a book of wide pages, such as
# I, Villain from test/modern.manifest.toml) every page after the cover
# must stand alone. COMICREDR_MODEL makes guided view use the model.
#
# Needs: Xvfb, xdotool, ImageMagick, zip, Python 3.
# Output: build/e2e-spreads/*.png and build/e2e-spreads/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-spreads
rm -rf "$out" && mkdir -p "$out/home" "$out/Comics" "$out/pages"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release

# The book with pages 5 and 6 joined: 01-04, 05 (wide), then the rest.
python3 - "$1" "$out/pages" <<'EOF'
import sys, zipfile, re
z = zipfile.ZipFile(sys.argv[1])
names = sorted((n for n in z.namelist() if re.search(r'\.(jpe?g|png|webp)$', n, re.I) and not n.startswith('__')),
               key=lambda n: [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', n)])
for i, n in enumerate(names[:12]):
    open(f"{sys.argv[2]}/{i:02d}{n[n.rfind('.'):].lower()}", 'wb').write(z.read(n))
EOF
cd "$out/pages"
p4=$(ls | sed -n 5p) p5=$(ls | sed -n 6p)
convert "$p4" "$p5" -resize x2000 +append -quality 90 "04.jpg.new"
rm "$p4" "$p5" && mv 04.jpg.new 04.jpg
zip -q ../Comics/Spread.cbz *
cd - >/dev/null
book="$PWD/$out/Comics/Spread.cbz"
[[ -n "${2:-}" ]] && cp "$2" "$out/Comics/Spreads.pdf"

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$1" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 1
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; }
step=${E2E_STEP:-1.5}
key() { xdotool key "$@" 2>/dev/null; sleep "$step"; }
shot() { import -window root "$out/$1.png"; }
sql() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$db" "$1"; }
# The saved page of the book open now, the one read last.
page() { sleep 1.2; sql "select page from progress order by updated_at desc limit 1"; }
# The height of what is drawn above the status line: the pages, found by
# trimming the reader's plain background.
height() { convert "$out/$1.png" -crop 1280x800+0+60 +repage -fuzz 12% -trim -format '%h' info:; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: got $2, want $3"; failed=1; fi
}

# Two-page mode from the cover. Units: 0 | 1-2 | 3 | 4 (wide) | 5-6 | 7-8.
# The wide page takes the place of two, so page 3 is left without a
# partner, as in the printed book, and 5 is a left page again.
start "$book"
key d
shot unit0
pages=()
for i in 1 2 3 4 5; do
  key l
  shot "unit$i"
  pages+=("$(page)")
done
check "first page of each unit after the cover" "${pages[*]}" "1 3 4 5 7"
full=$(height unit0)
for i in 3 4; do
  h=$(height "unit$i")
  # A wide page paired with its neighbour would be squeezed to about half.
  (( h * 10 >= full * 8 )) && r=full || r=squeezed
  check "unit $i fills the height (${h}px of ${full}px)" "$r" full
done

# Back over the spread, then reopen on the pair after it.
key h; key h
check "back to the wide page" "$(page)" 4
key l
stop
start "$book"
shot reopened
check "reopened on the pair after the spread" "$(page)" 5
compare -metric AE -fuzz 10% <(convert "$out/unit4.png" -crop 1280x680+0+60 png:-) \
  <(convert "$out/reopened.png" -crop 1280x680+0+60 png:-) null: 2>"$out/diff.txt" || true
d=$(cut -d' ' -f1 <"$out/diff.txt")
check "reopened view matches (${d} pixels differ)" "$([[ ${d%.*} -lt 3000 ]] && echo same || echo different)" same

# Guided view on the spread: the camera starts on the left page.
key h
key v
sleep 3
shot guided_spread_1
key l
shot guided_spread_2
stop

if [[ -n "${2:-}" ]]; then
  pdf="$PWD/$out/Comics/Spreads.pdf"
  start "$pdf"
  key d
  step=3
  pdfpages=()
  for i in 1 2 3; do key l; pdfpages+=("$(page)"); shot "pdf$i"; done
  check "a book of wide pages steps one page at a time" "${pdfpages[*]}" "1 2 3"
  stop
fi

montage "$out"/unit*.png "$out"/reopened.png "$out"/guided_spread_*.png $( [[ -n "${2:-}" ]] && echo "$out"/pdf*.png ) \
  -tile 4x -geometry 640x450+4+4 "$out/contact.png"
echo "screenshots in $out"
exit "$failed"
