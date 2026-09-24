#!/usr/bin/env bash
# End-to-end check of fullscreen (`f`, F11) under a real window manager:
# Openbox in Xvfb, once as itself (a title bar drawn by the window manager)
# and once posing as GNOME Shell, so the app puts up its GNOME header bar.
# Each run reads into a book, goes fullscreen and checks with xprop and
# pixels that the window covers the screen with nothing but the page (no
# title bar, header bar, status line or progress bar, and no pointer after
# the mouse rests), that the mouse along the bottom brings the status line
# back, that the window manager leaving fullscreen is followed, that Esc
# leaves it on the same page, and that a restart comes back fullscreen.
#
#   tool/e2e_fullscreen.sh
#
# Makes its own book: pages the size of the screen, one flat colour each,
# so "only the page" is a pixel count.
#
# Needs: Xvfb, openbox, xdotool, wmctrl, xprop (x11-utils), ImageMagick,
# Python with Pillow.
# Output: build/e2e-fullscreen/<run>/*.png and build/e2e-fullscreen/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-fullscreen
rm -rf "$out" && mkdir -p "$out"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release

python3 - "$out/Colours.cbz" <<'EOF'
import io, sys, zipfile
from PIL import Image, ImageDraw
colours = [(200, 40, 40), (40, 160, 60), (40, 80, 200), (220, 180, 30), (160, 50, 170), (30, 170, 170)]
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for i, c in enumerate(colours):
        im = Image.new('RGB', (1280, 800), c)
        ImageDraw.Draw(im).rectangle([600, 360, 680, 440], fill=(255, 255, 255))
        b = io.BytesIO()
        im.save(b, 'PNG')
        z.writestr(f'{i + 1:02d}.png', b.getvalue())
EOF

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
wm=
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
sleep 1
openbox >/dev/null 2>&1 &
wm=$!
sleep 1

failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
key() { xdotool key "$@"; sleep 1; }
shot() { import -window root "$run/$1.png"; }
fullscreen() { xprop -id "$win" _NET_WM_STATE | grep -q _NET_WM_STATE_FULLSCREEN; }
# Share of the screen, or of a band of rows, in the colour of page $2.
share() {
  local img="$run/$1.png" rgb crop="${3:-}"
  rgb=$(python3 -c "print('rgb(%d,%d,%d)' % [(200,40,40),(40,160,60),(40,80,200),(220,180,30),(160,50,170),(30,170,170)][$2 - 1])")
  convert "$img" ${crop:+-crop "$crop" +repage} -fuzz 6% -fill black +opaque "$rgb" -fill white -opaque "$rgb" \
    -colorspace gray -format '%[fx:mean]' info:
}
# The screen is page $2 edge to edge: all of the top and bottom bands, and
# all but the white square in the middle.
only_page() {
  local all top bottom
  all=$(share "$1" "$2")
  top=$(share "$1" "$2" 1280x60+0+0)
  bottom=$(share "$1" "$2" 1280x70+0+730)
  echo "  $1: page colour on $all of the screen, $top of the top rows, $bottom of the bottom rows"
  python3 -c "import sys; sys.exit(0 if $all > 0.99 and $top > 0.999 and $bottom > 0.999 else 1)"
}
# Whether the X server's current cursor has no visible pixel.
pointer_hidden() {
  python3 - <<'EOF'
import ctypes, sys
from ctypes import c_short, c_ushort, c_ulong, c_char_p, POINTER, Structure
class Img(Structure):
    _fields_ = [('x', c_short), ('y', c_short), ('width', c_ushort), ('height', c_ushort),
                ('xhot', c_ushort), ('yhot', c_ushort), ('serial', c_ulong),
                ('pixels', POINTER(c_ulong)), ('atom', c_ulong), ('name', c_char_p)]
x11 = ctypes.CDLL('libX11.so.6'); xf = ctypes.CDLL('libXfixes.so.3')
x11.XOpenDisplay.restype = ctypes.c_void_p
xf.XFixesGetCursorImage.restype = POINTER(Img); xf.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
d = x11.XOpenDisplay(None)
im = xf.XFixesGetCursorImage(d).contents
visible = sum(1 for i in range(im.width * im.height) if im.pixels[i] >> 24 & 0xff)
sys.exit(0 if visible == 0 else 1)
EOF
}

launch() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$PWD/$out/Colours.cbz" >>"$run/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" 2>/dev/null || true
  sleep 1
}

quit() {
  kill "$app" 2>/dev/null || true
  wait "$app" 2>/dev/null || true
  app=
}

one_run() {
  local name=$1
  run="$out/$name"
  mkdir -p "$run"
  # A fresh install and no sidecar, so the book opens on page 1.
  rm -rf "$out/home" "$out"/.Colours.cbz.crdb* && mkdir -p "$out/home"
  echo "== $name (window manager says: $(xprop -id "$(xprop -root _NET_SUPPORTING_WM_CHECK | awk '{print $NF}')" _NET_WM_NAME | cut -d'"' -f2))"
  launch
  xdotool mousemove 640 400 click 1
  sleep 1
  key Right Right # page 3, blue
  shot 1_window
  if fullscreen; then fail "fullscreen before f"; else ok "a normal window at first"; fi
  if only_page 1_window 3; then fail "the windowed view already shows only the page"; else ok "windowed: title bar and status line show"; fi

  key f
  sleep 2 # the pointer rests
  shot 2_fullscreen
  if fullscreen; then ok "f: the window manager has the window fullscreen"; else fail "f did not make the window fullscreen"; fi
  local geo
  geo=$(xdotool getwindowgeometry "$win" | awk '/Geometry/ {print $2}')
  [[ $geo == 1280x800 ]] && ok "the window covers the screen ($geo)" || fail "the window is $geo, not 1280x800"
  only_page 2_fullscreen 3 && ok "only the page, on the same page (3)" || fail "something besides the page shows"
  pointer_hidden && ok "the pointer is hidden at rest" || fail "the pointer still shows at rest"

  xdotool mousemove 640 790
  sleep 0.6
  shot 3_mouse_at_bottom
  pointer_hidden && fail "the pointer stays hidden while moving" || ok "moving the mouse shows the pointer"
  only_page 3_mouse_at_bottom 3 && fail "the mouse at the bottom did not bring the status line" \
    || ok "the mouse along the bottom brings the status line"
  xdotool mousemove 640 300
  sleep 3
  shot 4_mouse_away
  only_page 4_mouse_away 3 && ok "away from the bottom it goes again" || fail "the status line stayed"

  key Right # page 4, yellow, still fullscreen
  sleep 2
  shot 5_next_page
  only_page 5_next_page 4 && ok "turning the page stays fullscreen" || fail "page 4 is not shown whole"

  wmctrl -i -r "$win" -b remove,fullscreen
  sleep 2
  shot 6_wm_left
  fullscreen && fail "wmctrl could not leave fullscreen" || ok "the window manager left fullscreen"
  only_page 6_wm_left 4 && fail "the app did not follow the window manager" || ok "the app followed: status line back"

  key F11
  sleep 1
  fullscreen && ok "F11: fullscreen again" || fail "F11 did not go fullscreen"
  key Escape
  sleep 1
  shot 7_esc
  fullscreen && fail "Esc did not leave fullscreen" || ok "Esc leaves fullscreen"
  [[ $(share 7_esc 4) > 0.3 ]] && ok "still on page 4, not back in the library" || fail "Esc left the book"

  key f
  sleep 1
  quit
  launch
  sleep 2
  shot 8_restart
  fullscreen && ok "a restart comes back fullscreen" || fail "a restart forgot fullscreen"
  only_page 8_restart 4 && ok "on page 4, only the page" || fail "the restart does not show only page 4"
  key Escape
  quit
}

one_run openbox
# Pose as GNOME Shell, so the app draws its own header bar (my_application.cc).
check=$(xprop -root _NET_SUPPORTING_WM_CHECK | awk '{print $NF}')
xprop -id "$check" -f _NET_WM_NAME 8u -set _NET_WM_NAME "GNOME Shell"
one_run header-bar

montage -label '%d/%f' "$out"/openbox/*.png "$out"/header-bar/*.png -tile 4x -geometry 480x300+6+6 \
  -background '#222' -fill white "$out/contact.png" 2>/dev/null || true
if grep -iE 'exception|error' "$out"/*/app.log | grep -viE 'libEGL|Atk-CRITICAL|dbind'; then
  fail "the app logged errors"
fi
[[ $failed == 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
