#!/usr/bin/env bash
# Screenshots and animated GIFs for the usage guide (docs/guide/), taken
# from the release build under Xvfb and driven by real keys, the way the
# e2e scripts do it. The library is made of free comics only: the
# public-domain books of test/corpus.manifest.toml and Pepper&Carrot
# episode 6 by David Revoy (CC BY 4.0), fetched from peppercarrot.com.
#
#   python3 spike/fetch_corpus.py --skip-model   # once, for test/corpus/
#   tool/guide_shots.sh [section...]             # all sections by default
#
# Sections: library reader guided parts keys touch bookmarks details
# dialogs history empty. They run in that order and later ones
# lean on what earlier ones did (a started book, a bookmark), so run a
# single section only after a full run. E2E_SKIP_BUILD=1 reuses the build.
#
# The android-*.webp pictures are not made here: they were taken by hand
# on the Android 14 emulator (APK_ABI=android-arm64,android-x64 make apk)
# with adb exec-out screencap, from the same comics with their sidecars
# pushed to /sdcard/Comics, and scaled to 540 px wide.
#
# Needs: Xvfb, xdotool, ImageMagick, ffmpeg, gifsicle, cwebp, sqlite3.
# Output: docs/guide/images/*.webp and *.gif; raw captures in build/guide/.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/guide
img=docs/guide/images
corpus=test/corpus
home="$PWD/$out/home"
comics="$home/Comics"
db="$comics/.comicredr/comicredr.sqlite"
app=build/linux/x64/release/bundle/comicredr
sections=("$@")
[[ ${#sections[@]} -gt 0 ]] || sections=(library reader guided parts keys touch bookmarks details dialogs history empty)
mkdir -p "$out/raw" "$img"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release

# The library: renamed copies, so titles read well in the reader.
if [[ ! -d "$comics" ]]; then
  mkdir -p "$comics/Golden age" "$comics/Silver age" "$comics/Pepper&Carrot"
  cp "$corpus/golden-age/all-top-comics-6.cbz" "$comics/Golden age/All Top Comics 6 (1959).cbz"
  cp "$corpus/golden-age/international-comics-004.cbz" "$comics/Golden age/International Comics 4 (1947).cbz"
  cp "$corpus/golden-age/mercy-for-millions.cbz" "$comics/Golden age/Mercy for Millions (1945).cbz"
  cp "$corpus/golden-age/weird-comics-004.cbz" "$comics/Golden age/Weird Comics 4 (1940).cbz"
  cp "$corpus/golden-age-pdf/first-love-illustrated-078.pdf" "$comics/Golden age/First Love Illustrated 78 (1957).pdf"
  cp "$corpus/silver-age/space-war-002.cbz" "$comics/Silver age/Space War 2 (1959).cbz"
  cp "$corpus/silver-age/reptisaurus-v2-005.cbz" "$comics/Silver age/Reptisaurus 5 (1962).cbz"
  ep="$comics/Pepper&Carrot/Episode 6 - The Potion Contest"
  mkdir -p "$ep"
  for i in 01 02 03 04 05 06 07 08 09; do
    curl -sfL -o "$ep/page-$i.jpg" \
      "https://www.peppercarrot.com/0_sources/ep06_The-Potion-Contest/low-res/en_Pepper-and-Carrot_by-David-Revoy_E06P$i.jpg"
  done
fi

export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
pid=
trap 'kill $pid $xvfb 2>/dev/null || true' EXIT
sleep 1

key() { xdotool key --delay 90 "$@" 2>/dev/null; sleep "${KS:-1.2}"; }
typ() { xdotool type --delay 70 "$1"; sleep 0.6; }
click() { xdotool mousemove "$1" "$2" click 1; sleep "${3:-1.2}"; }
park() { xdotool mousemove 1279 300; sleep 0.3; }
q() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$db" "$1"; }
# still NAME [WxH]: the window as it is, as WebP.
grab() { import -window root -crop "${2:-1280x720}+0+0" "$out/raw/$1.png"; }
still() {
  grab "$@"
  cwebp -quiet -q 82 "$out/raw/$1.png" -o "$img/$1.webp"
}
# rec NAME SECONDS [WxH]: records the screen in the background; then drive
# the app and call gif NAME to turn it into a small looping GIF.
rec() {
  ffmpeg -loglevel error -y -f x11grab -framerate 15 -video_size "${3:-1280x720}" -i "$DISPLAY" -t "$2" "$out/raw/$1.mkv" &
  recpid=$!
  sleep 0.8
}
gif() {
  wait "$recpid" || true
  ffmpeg -loglevel error -y -i "$out/raw/$1.mkv" -vf \
    "fps=${3:-8},scale=${2:-640}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$img/$1.gif"
  gifsicle -O3 --lossy=80 --batch "$img/$1.gif" 2>/dev/null || gifsicle -O3 --batch "$img/$1.gif"
}
start() {
  HOME="$home" "$app" "$@" >>"$out/app.log" 2>&1 &
  pid=$!
  sleep 8
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool windowmove "$win" 0 0 windowsize "$win" 1280 720 2>/dev/null || true
  sleep 1
  park
}
stop() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; sleep 1; }
# Waits for the whole-library panel pass, so guided view never waits.
detected() {
  for _ in $(seq 1 240); do
    [[ "$(q 'select count(*) from analysed_pages')" -ge "$(q 'select sum(page_count) from books')" ]] && return 0
    sleep 5
  done
}
# tab NAME: clicks a library tab in the rail of the 1280 px wide window.
tab() {
  local y
  case $1 in Reading) y=35 ;; Series) y=100 ;; Books) y=160 ;; Collections) y=228 ;;
    History) y=292 ;; Folders) y=356 ;; Bookmarks) y=420 ;; esac
  click 43 "$y"; park
}
clear_search() { key slash; xdotool key ctrl+a BackSpace; key Return; park; }
# open TITLE: finds a book with the library search and opens it.
open() {
  key Escape; key Escape; tab Books
  key slash; xdotool key ctrl+a; typ "$1"; key Return; key Return; sleep 2.5; park
}
# page N: jumps to page N (1-based) of the open book.
page() { key $(echo "$1" | sed 's/./& /g') shift+g; sleep 1; }

start
detected

for s in "${sections[@]}"; do case $s in

library)
  tab Series; key Right; still library
  tab Books; still books
  rec search 8; key slash; sleep 0.5; xdotool type --delay 200 "top 1959"; sleep 2; key Return; sleep 2; gif search
  key Escape
  tab Folders; key Right; still folders
  key Return; sleep 1.5; still folders-inside
  key Return; sleep 1.5; key shift+s; sleep 10; park; still shuffle
  key shift+s; key BackSpace; key BackSpace
  ;;

reader)
  open "all top"
  rec turning 9; for _ in 1 2 3 4; do key l; done; for _ in 1 2; do key h; done; gif turning
  page 4; still page
  page 5
  xdotool mousemove 780 666; sleep 2.5; still scrubber; park
  key p; sleep 4; still pages
  key plus; key plus; sleep 2; still pages-bigger; key equal; key Escape
  open "episode"
  key d; sleep 2; key l; sleep 2; still spread; key d
  key i; still night; key i
  open "international"
  # Fit width, so the paper and the ink show; the same half of the page
  # before and after, side by side.
  page 7; key z w; sleep 2; grab cleanup-before
  key c; sleep 4; grab cleanup-after; key c; key z z
  convert \( "$out/raw/cleanup-before.png" -crop 640x660+320+0 \) \( "$out/raw/cleanup-after.png" -crop 640x660+320+0 \) \
    +append +repage "$out/raw/cleanup.png"
  cwebp -quiet -q 82 "$out/raw/cleanup.png" -o "$img/cleanup.webp"
  open "episode"
  page 2
  rec rotate 13; key greater; sleep 1.5; key greater; sleep 1.5; key less; sleep 1.5; key g r; sleep 2; gif rotate
  key T; sleep 0.5; still clock
  sleep 3
  ;;

guided)
  open "all top"
  page 5
  rec guided 16; key v; sleep 2; for _ in 1 2 3 4 5 6 7 8; do KS=1.5 key l; done; gif guided
  key 5 shift+g; sleep 1; key v; sleep 1; key v; sleep 2; key l; key l; sleep 1; still guided
  key v; page 5; key v; sleep 1
  rec balloons 16; key b; sleep 2; for _ in 1 2 3 4 5 6 7 8; do KS=1.5 key l; done; gif balloons
  key l; sleep 1.5; still balloon
  key b; key v
  open "reptisaurus"
  page 2; key v; sleep 2
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    KS=0.8 key l
    [[ "$(q "select page from progress order by updated_at desc limit 1")" == 2 ]] && break
  done
  sleep 1.5; still held-whole
  rec held 8; sleep 1; key l; sleep 3; key l; sleep 2; gif held
  key v
  ;;

parts)
  open "mercy"
  page 4
  rec parts 14; key B 1; sleep 1.5; key l; sleep 1.5; key l; sleep 1.5; key Q 1; sleep 1.5; key l; sleep 1.5; key Escape; sleep 1.5; gif parts
  key H 1; sleep 1.5; still part-half; key Escape
  ;;

keys)
  key question; sleep 2; still keymap
  key slash; typ "bookmark"; sleep 1; still keymap-search
  key Escape; key Escape
  ;;

touch)
  open "all top"
  key g t; sleep 0.8; still touch-zones; sleep 4
  key Escape; key Escape; key Escape
  tab History; click 1252 28 2; still settings
  xdotool mousemove 640 400; for _ in $(seq 1 15); do xdotool click 5; done; sleep 1; still settings-touch
  key Escape
  ;;

bookmarks)
  open "all top"
  page 9; key m m; sleep 1.5; still bookmark-ribbon
  page 14; key v; sleep 2; key l; key l; key m m; key v
  key 2 0 shift+g; key m m
  key shift+m; sleep 2; key j; key e; typ "The chase starts"; key Return; sleep 1; still bookmark-list
  key Escape; key Escape; clear_search
  key shift+m; sleep 2; still bookmarks-tab
  ;;

details)
  open "all top"
  key shift+i; sleep 3; still details
  for _ in $(seq 1 3); do xdotool key Page_Down; sleep 0.3; done; sleep 1; still details-panels
  key Escape
  ;;

dialogs)
  key Escape; key Escape; tab Books
  key slash; xdotool key ctrl+a; typ "all top"; key Return
  key e; sleep 1.5; still edit; key Escape
  key asterisk; sleep 1; key g f; sleep 1.5; still favourites
  key Escape; key Escape; tab Books
  key slash; xdotool key ctrl+a; typ "space war"; key Return
  key asterisk; key Escape; clear_search
  key slash; xdotool key ctrl+a; typ "all top"; key Return
  key g d; sleep 1; still delete; key Escape
  key shift+x; sleep 1; still reset; key Escape
  ;;

history)
  key Escape; key Escape; clear_search
  tab Reading; still reading-tab
  tab History; still history
  ;;

empty)
  stop
  mkdir -p "$out/empty-home"
  HOME="$PWD/$out/empty-home" "$app" >>"$out/app.log" 2>&1 &
  pid=$!
  sleep 8; park
  still empty
  stop
  start
  ;;

*) echo "unknown section $s"; exit 1 ;;
esac; done

stop
ls -la "$img"
