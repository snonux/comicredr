#!/usr/bin/env bash
# differ_px.sh FUZZ A B [CROP]: how many pixels of the pictures A and B
# differ by more than FUZZ (as compare's -fuzz, e.g. 10%), both cut to CROP
# (WxH+X+Y) first when given. Prints a whole number.
#
# Counted from compare's mask of the differing pixels, not from the AE
# metric it prints: ImageMagick 7 prints that scaled by the quantum range
# and in exponent form (1.59546e+10), which the e2e scripts read as a count
# with ${d%.*} or (( )) and so got verdicts that meant nothing (task 773).
# The mask and fx's mean are the same in ImageMagick 6 and 7.
set -euo pipefail
fuzz=$1 a=$2 b=$3 crop=${4:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -n "$crop" ]]; then
  convert "$a" -crop "$crop" +repage "$tmp/a.png"
  convert "$b" -crop "$crop" +repage "$tmp/b.png"
  a=$tmp/a.png b=$tmp/b.png
fi
# compare exits 1 when the pictures differ, which is no error here.
compare -fuzz "$fuzz" "$a" "$b" -compose src -highlight-color white -lowlight-color black "$tmp/mask.png" 2>/dev/null || true
printf '%.0f\n' "$(convert "$tmp/mask.png" -format '%[fx:mean.r*w*h]' info:)"
