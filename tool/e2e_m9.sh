#!/usr/bin/env bash
# End-to-end check of M9 from the release tarball: unpack it, install it
# with its install.sh into a fresh HOME, remap keys with a keys.toml, and
# drive the installed app under a virtual X display: auto-trim, the night
# filter, guided view on a trimmed page, the ? overlay and its / search,
# and both settings surviving a restart. Screenshots show each step.
#
#   tool/e2e_m9.sh book.cbz
#
# The book's pages are padded with an off-white scanner margin, uneven and
# with a dark scanner edge, so auto-trim has something to cut on any book.
#
# E2E_SKIP_BUILD=1 reuses build/comicredr-*.tar.gz.
# Needs: Xvfb, xdotool, ImageMagick (import, montage), python3 + Pillow.
# Output: build/e2e-m9/shot_*.png and build/e2e-m9/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-m9
rm -rf "$out" && mkdir -p "$out/Comics" "$out/home" "$out/unpack"
home="$PWD/$out/home"
book="$PWD/$out/Comics/Scanned Margins.cbz"
python3 - "$1" "$book" <<'PY'
import io, random, sys, zipfile
from PIL import Image, ImageDraw
src, dst = sys.argv[1:]
with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED) as out:
    names = sorted(n for n in z.namelist() if n.lower().endswith((".jpg", ".jpeg", ".png")))
    for i, n in enumerate(names[:8], 1):
        im = Image.open(io.BytesIO(z.read(n))).convert("RGB")
        w, h = im.size
        l, t, r, b = int(w * .09), int(h * .06), int(w * .05), int(h * .11)
        page = Image.new("RGB", (w + l + r, h + t + b), (238, 234, 222))
        d = ImageDraw.Draw(page)
        rnd = random.Random(i)
        for _ in range(400):  # Paper grain and dust.
            x, y = rnd.randrange(page.width), rnd.randrange(page.height)
            d.point((x, y), fill=(120, 120, 120))
        d.rectangle([0, 0, 3, page.height], fill=(20, 20, 20))  # Scanner edge.
        page.paste(im, (l, t))
        buf = io.BytesIO()
        page.save(buf, "JPEG", quality=88)
        out.writestr(f"page{i:02}.jpg", buf.getvalue())
PY

[[ -n "${E2E_SKIP_BUILD:-}" ]] || make tarball
tar -C "$out/unpack" -xzf build/comicredr-*-linux-*.tar.gz
HOME="$home" "$out"/unpack/comicredr-*/install.sh
test -x "$home/.local/bin/comicredr"
test -f "$home/.local/share/applications/org.snonux.comicredr.desktop"
grep -q "Exec=$home/.local/bin/comicredr" "$home/.local/share/applications/org.snonux.comicredr.desktop"

# x instead of l for the next step, and one line the app must complain about.
mkdir -p "$home/.config/comicredr"
cat >"$home/.config/comicredr/keys.toml" <<'KEYS'
[keys]
nextStep = ["x", "Right"]   # l no longer turns the page
noSuchAction = "q"
KEYS

export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
launch() {
  HOME="$home" "$home/.local/bin/comicredr" "$book" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 6
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
}
trap 'kill ${app:-} $xvfb 2>/dev/null || true' EXIT
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
type() { xdotool type --delay 80 "$1" 2>/dev/null; sleep 1; }

launch
shot 01_open_keys_toml_warning
key 3 shift+g;          shot 02_page3
key l;                  shot 03_l_unbound_still_page3
key x;                  shot 04_x_next_page4
key t; sleep 1;         shot 05_trimmed
key v; sleep 2;         shot 06_guided_trimmed_whole_page
key x; sleep 1;         shot 07_guided_trimmed_panel1
key x; sleep 1;         shot 08_guided_trimmed_panel2
key v; key i;           shot 09_night_and_trim
key question;           shot 10_help
key slash; type "zoom"; shot 11_help_search_zoom
key ctrl+a; type "/^z[wh]/"; shot 12_help_search_regex
key Escape;             shot 13_help_search_cleared
key Escape;             shot 14_help_closed

# Both settings survive a restart.
kill "$app"; wait "$app" 2>/dev/null || true
launch
shot 15_restart_trim_and_night_kept

kill "$app"; wait "$app" 2>/dev/null || true
HOME="$home" "$out"/unpack/comicredr-*/install.sh --uninstall
test ! -e "$home/.local/bin/comicredr"
test ! -e "$home/.local/lib/comicredr"
montage "$out"/shot_*.png -tile 4x -geometry 640x450+4+4 -title "M9 e2e" "$out/contact.png"
echo "OK: see $out/contact.png"
