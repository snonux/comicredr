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
if (( $# == 0 )); then
  echo 'Usage: tool/e2e_sidecar.sh comic.cbz [another.pdf folder/ ...]' >&2
  exit 2
fi

out=build/e2e-sidecar
rm -rf "$out" && mkdir -p "$out/laptop-home" "$out/phone-home" "$out/laptop" "$out/phone"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
model="${COMICREDR_MODEL:-$PWD/assets/models/comicredr-panels.onnx}"
model=$(realpath "$model")
unset COMICREDR_MODEL

Xvfb -displayfd 3 -screen 0 1280x900x24 3>"$out/display" >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true; mountpoint -q "$PWD/$out/ro" && umount "$PWD/$out/ro"' EXIT
for _ in $(seq 1 100); do [[ -s $out/display ]] && break; sleep 0.1; done
[[ -s $out/display ]] || { echo "FAIL Xvfb did not select a display"; exit 1; }
DISPLAY=":$(<"$out/display")"
export DISPLAY
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL Xvfb did not come up on $DISPLAY"; exit 1; }

failed=0
check() { # check "what" test-command...
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}

start() { # start laptop|phone book [readonly]
  local home="$PWD/$out/$1-home"
  local ready_side written_before='' written_now=''
  if [[ ${3:-} != readonly ]]; then
    if [[ $1 == laptop ]]; then ready_side=$side; else ready_side=$copyside; fi
    if [[ -f $ready_side ]]; then
      written_before=$(q "$ready_side" 'select written_at from meta limit 1' 2>/dev/null || true)
    fi
  fi
  if [[ $1 == laptop ]]; then
    COMICREDR_MODEL="$model" HOME="$home" GDK_BACKEND=x11 G_MESSAGES_DEBUG=all \
      build/linux/x64/release/bundle/comicredr "$2" >>"$out/$1.log" 2>&1 &
  else
    HOME="$home" GDK_BACKEND=x11 G_MESSAGES_DEBUG=all \
      build/linux/x64/release/bundle/comicredr "$2" >>"$out/$1.log" 2>&1 &
  fi
  app=$!
  # A busy container can need more than seven seconds for the first frame.
  win=
  for _ in $(seq 1 150); do
    win=$(xdotool search --name ComicRedr 2>/dev/null | tail -1 || true)
    [[ -n $win ]] && break
    sleep 0.2
  done
  [[ -n $win ]] || { echo "FAIL ComicRedr window did not appear"; return 1; }
  if [[ ${3:-} == readonly ]]; then
    # Here no sidecar can be written. The book-specific refusal log proves
    # that this launch got as far as trying to save the open comic.
    for _ in $(seq 1 300); do
      grep -Fq "Cannot write the sidecar of $2" "$out/$1.log" 2>/dev/null && break
      sleep 0.1
    done
    grep -Fq "Cannot write the sidecar of $2" "$out/$1.log" ||
      { echo "FAIL read-only comic did not open"; return 1; }
  else
    # open() writes the sidecar once it has installed the book and imported
    # any incoming data. Reused sidecars must get a new written_at too; an
    # existing progress row alone would say nothing about this launch.
    for _ in $(seq 1 300); do
      if [[ -f $ready_side ]]; then
        written_now=$(q "$ready_side" 'select written_at from meta limit 1' 2>/dev/null || true)
        [[ -n $written_now && $written_now != "$written_before" ]] && break
      fi
      sleep 0.1
    done
    [[ -n $written_now && $written_now != "$written_before" ]] ||
      { echo "FAIL $1 did not open this comic and write its sidecar"; return 1; }
  fi
  sleep 1 # Let the page and, where offered, the position dialog paint.
  # Under Xvfb keys go to the window under the pointer.
  xdotool windowactivate --sync "$win" mousemove 640 400 2>/dev/null || true
  sleep 1
}
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
shot() { import -window root "$out/$1.png"; }
stop() {
  "$PWD/$out/close_window" "$win"
  for _ in $(seq 1 30); do
    if ! kill -0 "$app" 2>/dev/null; then
      if wait "$app"; then
        echo 'PASS app closed cleanly'
      else
        echo "FAIL app exited abnormally: $?"
        failed=1
      fi
      return
    fi
    sleep 0.25
  done
  echo 'FAIL the app did not quit on close'
  failed=1
  kill "$app"
  wait "$app" 2>/dev/null || true
}
q() { sqlite3 -batch -noheader "$1" "$2"; }
index() { echo "$PWD/$out/$1-home/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
spot() {
  q "$(index "$1")" "select page || '/' || coalesce(cast(panel as text), '<null>') || '/' ||
    coalesce(cast(json_extract(view_json, '$.guided') as text), '<null>')
    from progress where content_key = '$bookkey'"
}
valid_spot() { [[ -n $1 && $1 != *'<null>'* ]]; }
page_at() { q "$(index "$1")" "select page from progress where content_key = '$bookkey'"; }
sidecar_spot() {
  q "$1" "select page || '/' || coalesce(cast(panel as text), '<null>') || '/' ||
    coalesce(cast(json_extract(view_json, '$.guided') as text), '<null>')
    from progress where device = (select device from meta limit 1)"
}
# Two screenshots of the page area, the status line cropped off.
same() {
  local diff
  # The two installs can paint different gutters around the page. Compare
  # the artwork; the index checks below verify its page and panel position.
  diff=$(tool/differ_px.sh 10% "$out/$1.png" "$out/$2.png" 400x550+430+40)
  echo "  $1 vs $2: $diff pixels differ"
  [[ "$diff" -lt 3000 ]]
}

n=0
for src in "$@"; do
  n=$((n + 1))
  name=$(basename "$src")
  cp -r "$src" "$out/laptop/$name"
  book="$PWD/$out/laptop/$name"
  if [[ -d $book ]]; then side="$book/.comicredr.crdb"; else side="$(dirname "$book")/.$(basename "$book").crdb"; fi
  echo "== $name"

  # 1. The laptop: start on page 3, read onward in guided view, mark a and a bookmark.
  start laptop "$book"
  key shift+g 3 Return; key v; sleep 4
  # A page guided view shows whole holds one step (e2e_pause_whole.sh checks
  # that); off here, so `l` below always moves. The setting stays with the
  # laptop, so W once.
  [[ $n -gt 1 ]] || key shift+w
  key m a; key m m; key l; sleep 1 # A page with one panel steps on to page 4.
  shot "b${n}_laptop"
  stop
  check "laptop wrote the sidecar" test -f "$side"
  bookkey=$(q "$side" 'select content_key from meta limit 1')
  check "laptop has a progress row for this comic" test -n "$(spot laptop)"
  check "laptop's page, panel and mode are present" valid_spot "$(spot laptop)"
  check "laptop read on from page 3" test "$(page_at laptop)" -gt 2
  check "laptop is in guided view" test "$(q "$(index laptop)" "select json_extract(view_json, '$.guided') from progress where content_key = '$bookkey'")" = 1
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
  check "phone's page, panel and mode are present" valid_spot "$(spot phone)"
  check "phone resumed at the laptop's page, panel and mode" test "$(spot phone)" = "$(spot laptop)"

  # 3. The phone reads on two pages; its sidecar goes back to the laptop.
  sleep 1 # Positions are kept to the second.
  start phone "$copy"
  # The GTK close callback must receive Dart's successful flush reply. Its
  # debug line identifies that close even when a slow machine lets the
  # sidecar's timer fire before the window-close request.
  flushes_before=$(grep -c 'ComicRedr reader flushed before window close' "$out/phone.log" || true)
  xdotool key Next Next
  stop
  flushes_after=$(grep -c 'ComicRedr reader flushed before window close' "$out/phone.log" || true)
  check "Linux close waited for the reader flush" test "$flushes_after" -gt "$flushes_before"
  check "phone read on from its imported page" test "$(page_at phone)" -gt "$(page_at laptop)"
  check "phone's close flushed its page, panel and mode to the sidecar" \
    test "$(sidecar_spot "$copyside")" = "$(spot phone)"
  start phone "$copy"
  shot "b${n}_phone_on"
  stop
  cp "$copyside" "$side"
  start laptop "$book"
  shot "b${n}_offer"
  key Return; sleep 4
  shot "b${n}_taken"
  stop
  check "laptop took the phone's page, panel and mode" test "$(spot laptop)" = "$(spot phone)"
  check "laptop shows the phone's spot" same "b${n}_phone_on" "b${n}_taken"
done

# A read-only shelf: opens, says so, writes nothing.
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$out/ro-src" "$out/ro"
  cp -r "$1" "$out/ro-src/"
  sidecars_before=$(find "$out/ro-src" -type f -name '*.crdb' -printf '%P\n' | sort)
  mount --bind "$out/ro-src" "$out/ro" && mount -o remount,bind,ro "$out/ro"
  start laptop "$PWD/$out/ro/$(basename "$1")" readonly
  key shift+g 2 Return
  shot ro
  stop
  umount "$out/ro"
  sidecars_after=$(find "$out/ro-src" -type f -name '*.crdb' -printf '%P\n' | sort)
  check "read-only shelf: no sidecar written" test "$sidecars_after" = "$sidecars_before"
  check "read-only shelf: position kept in the index" \
    test "$(q "$(index laptop)" "select page from progress order by updated_at desc limit 1")" = 1
  if grep -q "Cannot write the sidecar" "$out/laptop.log"; then
    echo "PASS read-only notice logged"
  else
    echo "FAIL read-only notice"
    failed=1
  fi
else
  echo "SKIP read-only shelf (needs root for a read-only bind mount)"
fi

shots=()
for i in $(seq 1 "$n"); do shots+=("$out/b${i}_laptop.png" "$out/b${i}_phone.png" "$out/b${i}_offer.png" "$out/b${i}_taken.png"); done
montage "${shots[@]}" -tile 4x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
if [[ $failed -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
