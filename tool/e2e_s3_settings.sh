#!/usr/bin/env bash
# End-to-end check of Settings → S3 sync (design plan section 13) on the
# Linux build under Xvfb with Openbox, against a real bucket: the one in
# GARAGE_TEST_* (tool/garage_local.sh starts a local Garage and prints them;
# a real Garage works the same). Typed into the dialog by keys:
#
#  - a wrong secret key: Test connection says the keys were refused
#    (02_wrong_secret.png);
#  - the right one with the server off (a dead port): no answer, within
#    seconds (03_server_off.png);
#  - the right one: connected, the check object is gone from the bucket
#    again, Save;
#  - the index holds the bucket, the access key id and no secret; with no
#    keyring running the secret is in ~/.config/comicredr/s3-secret, 0600;
#  - after a restart the dialog says a secret is saved, Test connection
#    works with the field left empty;
#  - Turn off forgets the settings and the secret file.
#
#   eval "$(tool/garage_local.sh env)"; tool/garage_local.sh start; tool/e2e_s3_settings.sh
#
# Skipped (exit 0) without GARAGE_TEST_ENDPOINT. E2E_SKIP_BUILD=1 reuses the
# release build in build/. Needs: Xvfb, openbox, xdotool, ImageMagick,
# sqlite3, curl, Python 3, a C compiler, X11 headers.
# Output: build/e2e-s3-settings/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${GARAGE_TEST_ENDPOINT:-}" ]]; then
  echo "SKIP GARAGE_TEST_ENDPOINT is not set (tool/garage_local.sh env)"
  exit 0
fi
: "${GARAGE_TEST_BUCKET:?}" "${GARAGE_TEST_ACCESS_KEY_ID:?}" "${GARAGE_TEST_SECRET_ACCESS_KEY:?}"
region=${GARAGE_TEST_REGION:-garage}
prefix="comicredr-e2e-$(date +%s)"

out=build/e2e-s3-settings
rm -rf "$out" && mkdir -p "$out/home/Comics"
home="$PWD/$out/home"

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/close_window.c -lX11
export DISPLAY=:94
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
openbox >/dev/null 2>&1 &
wm=$!
app=
# No D-Bus session, so no Secret Service: the secret must go to its file.
unset DBUS_SESSION_BUS_ADDRESS
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
sleep 1

failed=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS $what"; else echo "FAIL $what"; failed=1; fi
}
db="$home/Comics/.comicredr/comicredr.sqlite"
secret_file="$home/.config/comicredr/s3-secret"
q() { sqlite3 -batch -noheader "$db" "$1"; }
setting() { q "select value from settings where key = '$1'"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.6; }
type_() { xdotool type --delay 15 "$1" 2>/dev/null; sleep 0.3; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
shot() { import -window root "$out/$1.png"; }
start() {
  HOME="$home" build/linux/x64/release/bundle/comicredr >>"$out/app.log" 2>&1 &
  app=$!
  sleep 7
  win=$(xdotool search --name "^ComicRedr$" | tail -1)
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 30); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.25; done
  echo "FAIL the app did not quit on close"; failed=1; kill "$app"
}
origin() {
  local info
  info=$(xwininfo -id "$win")
  ox=$(awk '/Absolute upper-left X/ {print $NF}' <<<"$info")
  oy=$(awk '/Absolute upper-left Y/ {print $NF}' <<<"$info")
  w=$(awk '/Width:/ {print $NF}' <<<"$info")
  h=$(awk '/Height:/ {print $NF}' <<<"$info")
}
# The gear, the Settings dialog scrolled to its end, then "Set up S3 sync…",
# a fixed way up from the bottom of the dialog.
s3_dialog() {
  origin
  click $((ox + w - 30)) $((oy + 28))
  xdotool mousemove $((ox + w / 2)) $((oy + h / 2)) click --repeat 20 --delay 50 5; sleep 1
  click $((ox + w / 2 - ${S3_BUTTON_DX:-168})) $((oy + h - ${S3_BUTTON_DY:-152}))
}
# The S3 dialog opens with the address focused; Tab walks the fields in order.
fill() { # fill endpoint region bucket prefix access secret
  local f
  for f in "$@"; do
    key ctrl+a
    if [[ -n $f ]]; then type_ "$f"; else key BackSpace; fi
    key Tab
  done
}
# From the secret field: Tab to Test connection, Space presses it.
test_connection() { key space; sleep "${1:-4}"; }
# From Test connection: Tab past Turn off (when shown) and Cancel to Save.
save() { # save TABS
  local i
  for ((i = 0; i < $1; i++)); do key Tab; done
  key space; sleep 1.5
}
objects() { # the keys under the run's prefix, through the Garage S3 API
  curl -sS --aws-sigv4 "aws:amz:$region:s3" \
    --user "$GARAGE_TEST_ACCESS_KEY_ID:$GARAGE_TEST_SECRET_ACCESS_KEY" \
    "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET?list-type=2&prefix=$prefix/" |
    grep -o '<Key>[^<]*</Key>' || true
}

start
s3_dialog
shot 01_dialog

# A wrong secret key, then the right one on a port nothing answers. After
# each test the focus is on Test connection; six Shift+Tabs are the address.
back() { for _ in 1 2 3 4 5 6; do key shift+Tab; done; }
fill "$GARAGE_TEST_ENDPOINT" "$region" "$GARAGE_TEST_BUCKET" "$prefix" "$GARAGE_TEST_ACCESS_KEY_ID" "wrong-secret"
test_connection
shot 02_wrong_secret
back
fill "http://127.0.0.1:9" "$region" "$GARAGE_TEST_BUCKET" "$prefix" "$GARAGE_TEST_ACCESS_KEY_ID" \
  "$GARAGE_TEST_SECRET_ACCESS_KEY"
before=$(date +%s)
test_connection 1
sleep 4
after=$(date +%s)
shot 03_server_off
check "the server off is found out in seconds" test $((after - before)) -lt 15

# The right address: connected, and the check leaves nothing behind.
back
fill "$GARAGE_TEST_ENDPOINT" "$region" "$GARAGE_TEST_BUCKET" "$prefix" "$GARAGE_TEST_ACCESS_KEY_ID" \
  "$GARAGE_TEST_SECRET_ACCESS_KEY"
test_connection
shot 04_connected
check "the connection check leaves nothing in the bucket" test -z "$(objects)"
save 2
sleep 3
shot 05_saved

check "the index holds the bucket" test "$(setting s3.bucket)" = "\"$GARAGE_TEST_BUCKET\""
check "the index holds the access key id" test "$(setting s3.accessKey)" = "\"$GARAGE_TEST_ACCESS_KEY_ID\""
check "the index holds the prefix, with its slash" test "$(setting s3.prefix)" = "\"$prefix/\""
check "no secret in the index" bash -c "! sqlite3 '$db' .dump | grep -qF '$GARAGE_TEST_SECRET_ACCESS_KEY'"
check "the secret is in its own file" test "$(cat "$secret_file" 2>/dev/null)" = "$GARAGE_TEST_SECRET_ACCESS_KEY"
check "only this user can read it" test "$(stat -c %a "$secret_file")" = 600
check "no secret anywhere else in HOME" bash -c \
  "test \$(grep -rlF '$GARAGE_TEST_SECRET_ACCESS_KEY' '$home' 2>/dev/null | wc -l) -eq 1"
key Escape
stop

# A restart: the dialog knows a secret is saved and tests with the field empty.
start
s3_dialog
shot 06_reopened
for _ in 1 2 3 4 5 6; do key Tab; done
test_connection
shot 07_connected_again
key Escape
stop

# Turn off: the settings and the secret file go; the bucket keeps nothing of ours.
start
s3_dialog
for _ in 1 2 3 4 5 6 7; do key Tab; done
key space; sleep 1
shot 08_turn_off
key Tab; key space; sleep 1.5
shot 09_off
check "turned off: no S3 settings left" test -z "$(q "select key from settings where key like 's3.%'")"
check "turned off: the secret file is gone" test ! -e "$secret_file"
check "nothing of this run is left in the bucket" test -z "$(objects)"
stop

montage "$out"/0*.png -tile 3x -geometry 640x450+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed == 0 ]] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
