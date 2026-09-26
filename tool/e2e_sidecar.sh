#!/usr/bin/env bash
# End-to-end check of the per-comic sidecar on the Linux build, with two
# installs standing in for the laptop and the phone: two HOMEs, so two
# indexes and two device ids. The laptop has the trained model; the phone
# has only classic CV.
#
#   COMICREDR_MODEL=comicredr-panels.onnx tool/e2e_sidecar.sh a.cbz b.pdf folder/
#
# For each book:
#   1. The laptop reads it in guided view from page 3, sets mark a and a
#      bookmark, steps one panel on, and closes. The sidecar must hold model panels, both
#      bookmarks and the position.
#   2. The book and its sidecar are copied to the "phone" shelf; a CBZ is
#      renamed on the way, leaving its sidecar orphaned. The phone opens the
#      copy and must re-link the sidecar, resume on the same page and panel,
#      and show the model's panels there without detecting that page.
#   3. The phone reads on and closes; its sidecar goes back to the laptop,
#      which must offer the phone's position in a dialog, and take it on
#      Enter.
# Then a read-only copy of the shelf (a read-only bind mount, needs root)
# must open with a notice and write nothing.
#
# Needs: Xvfb, xdotool, ImageMagick, sqlite3, a C compiler, X11 headers.
# Output: build/e2e-sidecar/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-sidecar
rm -rf "$out" && mkdir -p "$out/laptop-home" "$out/phone-home" "$out/laptop" "$out/phone"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
model="${COMICREDR_MODEL:-$PWD/assets/models/comicredr-panels.onnx}"
model=$(realpath "$model")
unset COMICREDR_MODEL

export DISPLAY=:97
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true; mountpoint -q "$PWD/$out/ro" && umount "$PWD/$out/ro"' EXIT

failed=0
check() { # check "what" test-command...
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}

start() { # start laptop|phone book
  local home="$PWD/$out/$1-home"
  if [[ $1 == laptop ]]; then
    COMICREDR_MODEL="$model" HOME="$home" build/linux/x64/release/bundle/comicredr "$2" >>"$out/$1.log" 2>&1 &
  else
    HOME="$home" build/linux/x64/release/bundle/comicredr "$2" >>"$out/$1.log" 2>&1 &
  fi
  app=$!
  sleep 7 # Opening, the sidecar, detection of the page on screen.
  win=$(xdotool search --name ComicRedr | tail -1)
  # Under Xvfb keys go to the window under the pointer.
  xdotool windowactivate --sync "$win" mousemove 640 400 2>/dev/null || true
  sleep 1
}
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
shot() { import -window root "$out/$1.png"; }
stop() {
  "$PWD/$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || { sleep 0.5; return 0; }; sleep 0.25; done
  echo "the app did not quit on close"; failed=1; kill "$app"
}
q() { sqlite3 -batch -noheader "$1" "$2"; }
index() { echo "$PWD/$out/$1-home/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
# Two screenshots of the page area, the status line cropped off.
same() {
  local diff
  diff=$(compare -metric AE -fuzz 10% <(convert "$out/$1.png" -crop 1280x680+0+0 png:-) \
    <(convert "$out/$2.png" -crop 1280x680+0+0 png:-) null: 2>&1 || true)
  echo "  $1 vs $2: ${diff%% *} pixels differ"
  [[ "${diff%% *}" -lt 3000 ]]
}

n=0
for src in "$@"; do
  n=$((n + 1))
  name=$(basename "$src")
  cp -r "$src" "$out/laptop/$name"
  book="$PWD/$out/laptop/$name"
  if [[ -d $book ]]; then side="$book/.comicredr.crdb"; else side="$(dirname "$book")/.$(basename "$book").crdb"; fi
  echo "== $name"

  # 1. The laptop: page 3, guided view, mark a, a bookmark, panel 2.
  start laptop "$book"
  key 3 shift+g; key v; sleep 4
  key m a; key m m; key l; sleep 1 # A page with one panel steps on to page 4.
  shot "b${n}_laptop"
  stop
  check "laptop wrote the sidecar" test -f "$side"
  check "sidecar has model panels for page 3" \
    test "$(q "$side" "select count(*) from analysed_pages where page = 2 and source = 'model'")" = 1
  check "sidecar has mark a and a bookmark" \
    test "$(q "$side" "select count(*) from bookmarks where deleted_at is null")" = 2
  check "sidecar has the laptop's position" \
    test "$(q "$side" "select page from progress")" = "$(q "$(index laptop)" "select page from progress order by updated_at desc limit 1")"
  echo "  sidecar: $(stat -c %s "$side") bytes, $(q "$side" 'select count(*) from panels') panel rows"

  # 2. Copied to the phone; a CBZ is renamed and its sidecar left behind.
  if [[ -d $book ]]; then
    cp -r "$book" "$out/phone/$name"
    copy="$PWD/$out/phone/$name"; copyside="$copy/.comicredr.crdb"
  elif [[ $name == *.cbz ]]; then
    copy="$PWD/$out/phone/renamed-$name"; copyside="$PWD/$out/phone/.renamed-$name.crdb"
    # Under the old visible name, as an older install would have copied it.
    cp "$book" "$copy"; cp "$side" "$PWD/$out/phone/$name.crdb"
  else
    copy="$PWD/$out/phone/$name"; copyside="$PWD/$out/phone/.$name.crdb"
    cp "$book" "$copy"; cp "$side" "$copyside"
  fi
  start phone "$copy"
  shot "b${n}_phone"
  stop
  check "phone found the sidecar" test -f "$copyside"
  [[ $name == *.cbz ]] && check "orphan re-linked" test ! -e "$PWD/$out/phone/$name.crdb"
  check "phone resumed on the laptop's page and panel" same "b${n}_laptop" "b${n}_phone"
  check "phone did not detect page 3 itself" \
    test "$(q "$(index phone)" "select group_concat(source) from analysed_pages where page = 2 and model_ver >= 0 \
      and content_key = (select content_key from progress order by updated_at desc limit 1)")" = model
  check "phone has both bookmarks" \
    test "$(q "$(index phone)" "select count(*) from bookmarks where deleted_at is null \
      and content_key = (select content_key from progress order by updated_at desc limit 1)")" = 2

  # 3. The phone reads on two pages; its sidecar goes back to the laptop.
  sleep 1 # Positions are kept to the second.
  start phone "$copy"
  key Next; key Next; sleep 1
  shot "b${n}_phone_on"
  stop
  cp "$copyside" "$side"
  start laptop "$book"
  shot "b${n}_offer"
  key Return; sleep 4
  shot "b${n}_taken"
  stop
  check "laptop took the phone's page" \
    test "$(q "$(index laptop)" "select page from progress order by updated_at desc limit 1")" = \
      "$(q "$copyside" "select page from progress order by updated_at desc limit 1")"
  check "laptop shows the phone's spot" same "b${n}_phone_on" "b${n}_taken"
done

# A read-only shelf: opens, says so, writes nothing.
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$out/ro-src" "$out/ro"
  cp -r "$1" "$out/ro-src/"
  mount --bind "$out/ro-src" "$out/ro" && mount -o remount,bind,ro "$out/ro"
  start laptop "$PWD/$out/ro/$(basename "$1")"
  key 2 shift+g
  shot ro
  stop
  umount "$out/ro"
  check "read-only shelf: no sidecar written" test "$(ls -A "$out/ro-src" | wc -l)" = 1
  check "read-only shelf: position kept in the index" \
    test "$(q "$(index laptop)" "select page from progress order by updated_at desc limit 1")" = 1
  grep -q "Cannot write a sidecar" "$out/laptop.log" && echo "PASS read-only notice logged" ||
    { echo "FAIL read-only notice"; failed=1; }
else
  echo "SKIP read-only shelf (needs root for a read-only bind mount)"
fi

shots=()
for i in $(seq 1 "$n"); do shots+=("$out/b${i}_laptop.png" "$out/b${i}_phone.png" "$out/b${i}_offer.png" "$out/b${i}_taken.png"); done
montage "${shots[@]}" -tile 4x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed -eq 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
