#!/usr/bin/env bash
# Real Linux keyboard check: sidebar focus, all destination letters,
# underlines shown only there, arrows, exits, search and prefix isolation.
# Needs Xvfb, Openbox, xdotool, ImageMagick, Tesseract and sqlite3.
# Makes its own comic; screenshots land in build/e2e-sidebar-keys/.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$PWD/build/e2e-sidebar-keys"
app="$PWD/build/linux/x64/release/bundle/comicredr"
rm -rf "$out"
mkdir -p "$out/home" "$out/Comics" "$out/pages"
convert -size 800x1200 xc:white -fill blue \
  -draw 'rectangle 40,40 760,560' "$out/pages/1.jpg"
python3 - "$out" <<'PY'
import sys, zipfile
from pathlib import Path
out = Path(sys.argv[1])
# Two pages and three: a one-page comic counts as completed once opened,
# which ga leaves out, and the page counts give two content keys.
with zipfile.ZipFile(out / 'Comics/Alpha 1.cbz', 'w') as archive:
    for n in (1, 2):
        archive.write(out / 'pages/1.jpg', f'{n}.jpg')
with zipfile.ZipFile(out / 'Comics/Bravo 1.cbz', 'w') as archive:
    for n in (1, 2, 3):
        archive.write(out / 'pages/1.jpg', f'{n}.jpg')
PY
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=${E2E_DISPLAY:-:97}
Xvfb "$DISPLAY" -screen 0 1280x900x24 >"$out/xvfb.log" 2>&1 &
xvfb=$!
pid=
wm=
trap 'kill ${pid:-} ${wm:-} "$xvfb" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.1
done
openbox >"$out/openbox.log" 2>&1 &
wm=$!
HOME="$out/home" XDG_DATA_HOME="$out/home/.local/share" \
  XDG_CONFIG_HOME="$out/home/.config" XDG_CACHE_HOME="$out/home/.cache" \
  GDK_BACKEND=x11 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent \
  COMICREDR_MODEL=none "$app" --add-root "$out/Comics" \
  >"$out/app.log" 2>&1 &
pid=$!
sleep 7
win=$(xdotool search --name ComicRedr | tail -1)
xdotool windowactivate --sync "$win"
xdotool mousemove 1279 850
key() {
  local token
  for token in "$@"; do
    xdotool key "$token"
    sleep 0.4
  done
}
shot() { import -window "$win" "$out/$1.png"; }
# Exact rail images prove focus hints appear and disappear without changing
# the selected destination. OCR proves which destination's content showed.
rail() { convert "$out/$1.png" -crop 85x480+0+0 +repage "$out/rail-$1.png"; }
same() {
  if ! compare -metric AE "$out/rail-$1.png" "$out/rail-$2.png" \
      null: 2>"$out/difference"; then
    echo "FAIL sidebar hints differ: $1 and $2" >&2
    exit 1
  fi
}
shot initial; rail initial
key Tab
shot focused; rail focused
if compare -metric AE "$out/rail-initial.png" "$out/rail-focused.png" \
    null: 2>"$out/difference"; then
  echo 'FAIL Tab showed no sidebar hints' >&2
  exit 1
fi
key Tab
shot unfocused; rail unfocused; same initial unfocused
# Outside the sidebar B must not navigate.
key b
shot outside; rail outside; same initial outside
key Tab
for letter in r b c h f m; do
  key "$letter"
  shot "letter-$letter"
  case $letter in
    r) label=Reading ;; b) label=Books ;;
    c) label=Collections ;; h) label=History ;; f) label=Folders ;;
    m) label=Bookmarks ;;
  esac
  convert "$out/letter-$letter.png" -crop 450x60+90+0 +repage \
    "$out/header.png"
  if ! tesseract "$out/header.png" stdout --psm 6 2>/dev/null \
      | rg -qi "$label"; then
    echo "FAIL $letter did not show $label" >&2
    exit 1
  fi
done
# Home selects Reading, Down the next, End Bookmarks, Up the one before;
# B selects Books.
key Home Down End Up b Return
key g g
shot details-unfocused; rail details-unfocused
key Tab
xdotool mousemove --window "$win" 1060 16 click 1
xdotool mousemove 1279 850
sleep 0.6
shot details-pointer; rail details-pointer
same details-unfocused details-pointer
key c # A passive details tap must release the sidebar's letter keys.
key Return
sleep 2
# The selected book opened: actual reader/index behavior, not only pictures.
db="$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"
[[ "$(sqlite3 "$db" 'select count(*) from progress')" == 1 ]]
key Escape
key Tab g Tab c
shot no-prefix-dialog
# A leaked g would make gc open the collection question.
if tesseract "$out/no-prefix-dialog.png" stdout 2>/dev/null \
    | rg -qi 'Add to a collection'; then
  echo 'FAIL sidebar prefix escaped into content' >&2
  exit 1
fi
key Tab
xdotool mousemove --window "$win" 250 24 click 1
sleep 0.5
xdotool type 'bcfh'
sleep 0.5
shot search
convert "$out/search.png" -crop 800x60+90+0 +repage "$out/search-header.png"
search_text=$(tesseract "$out/search-header.png" stdout --psm 6 2>/dev/null)
search_result=$(tesseract "$out/search.png" stdout 2>/dev/null)
[[ "$search_result" == *bcfh* ]]
[[ "$search_text" == *Books* ]]
key Escape
shot search-left
# g and the tab's capital letter go to that tab from the covers, without
# the sidebar, and from an open comic, which closes first.
header_says() {
  shot "$1"
  # Only the title: the search box beside it would garble the OCR.
  convert "$out/$1.png" -crop 135x60+90+0 +repage -resize 200% "$out/header.png"
  if ! tesseract "$out/header.png" stdout --psm 7 2>/dev/null | rg -qi "$2"; then
    echo "FAIL $1 did not show $2" >&2
    exit 1
  fi
}
# The search left from above would hide Alpha: clear it, keys back to the covers.
key slash ctrl+a BackSpace Return
for pair in R:Reading B:Books C:Collections H:History M:Bookmarks F:Folders; do
  letter=${pair%%:*}
  key g "shift+${letter,,}"
  header_says "go-$letter" "${pair#*:}"
done
# Folders: the only library folder is open; select Alpha and read it.
key l Return
sleep 2
[[ "$(sqlite3 "$db" 'select count(*) from progress')" == 1 ]]
key g shift+h
sleep 1
header_says go-from-reader History
# ga: a random unread comic. Alpha was only looked at (two pages, still
# unread) and Bravo never opened. Over Alpha, ga can only open Bravo; over
# Bravo, only Alpha. The comic open is the first of the app's recent list.
newest() { sqlite3 "$db" "select json_extract(value, '\$[0].path') from settings where key = 'reader.recent'"; }
key g shift+f l Return # Folders, inside Comics: Alpha first.
sleep 2
[[ "$(newest)" == *Alpha* ]] || { echo "FAIL Alpha did not open: $(newest)" >&2; exit 1; }
key g a
sleep 2
[[ "$(newest)" == *Bravo* ]] || { echo "FAIL ga over Alpha did not open Bravo: $(newest)" >&2; exit 1; }
key g a
sleep 2
[[ "$(newest)" == *Alpha* ]] || { echo "FAIL ga over Bravo did not open Alpha: $(newest)" >&2; exit 1; }
key Escape
if rg -q 'Unhandled Exception|\[ERROR' "$out/app.log"; then
  echo 'FAIL errors in app log' >&2
  exit 1
fi
echo "Sidebar keyboard e2e passed; screenshots: $out"
