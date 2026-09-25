#!/usr/bin/env python3
"""Which part of a page a reader screenshot frames, for tool/e2e_regions.sh.

    region_check.py ref.png shot.png           # prints e.g. "thirds 2 7.3"
    region_check.py ref.png shot.png whole     # prints "whole 4.1"

ref.png shows the page whole; shot.png is the reader after a part key.
For every part of every split (halves, thirds, quarters) the part is cut
out of the page in ref.png, scaled the way guided view's camera frames it
(centred, 92% of the view on the tighter side) and compared with the
middle of shot.png. It prints the part that matches best and how far off
it is (mean difference per channel, 0-255), and with "whole" how far the
shot is from ref.png itself.
"""
import sys

from PIL import Image, ImageChops, ImageStat

W, H = 1280, 665  # The reader above the progress bar and status line.
SPLITS = {"halves": (1, 2), "thirds": (1, 3), "quarters": (2, 2)}


def view(path):
    return Image.open(path).convert("RGB").crop((0, 0, W, H))


def page_box(img):
    """The page on the black background."""
    mask = img.convert("L").point(lambda v: 255 if v > 24 else 0)
    return mask.getbbox()


def off(a, b):
    small = (96, 96)
    diff = ImageChops.difference(a.resize(small, Image.BILINEAR), b.resize(small, Image.BILINEAR))
    return sum(ImageStat.Stat(diff).mean) / 3


def framed(ref, shot, cols, rows, part):
    left, top, right, bottom = page_box(ref)
    pw, ph = (right - left) / cols, (bottom - top) / rows
    x0, y0 = left + (part % cols) * pw, top + (part // cols) * ph
    scale = min(W * 0.92 / pw, H * 0.92 / ph)
    # The middle half of the part: clear of the dimmed edges around it.
    want = ref.crop((round(x0 + pw / 4), round(y0 + ph / 4), round(x0 + 3 * pw / 4), round(y0 + 3 * ph / 4)))
    sw, sh = pw * scale / 2, ph * scale / 2
    got = shot.crop((round(W / 2 - sw / 2), round(H / 2 - sh / 2), round(W / 2 + sw / 2), round(H / 2 + sh / 2)))
    return off(want, got)


def main():
    ref, shot = view(sys.argv[1]), view(sys.argv[2])
    if len(sys.argv) > 3 and sys.argv[3] == "whole":
        box = page_box(ref)  # The page only: a held page's background is wine red.
        print(f"whole {off(ref.crop(box), shot.crop(box)):.1f}")
        return
    scores = [
        (framed(ref, shot, cols, rows, part), name, part + 1)
        for name, (cols, rows) in SPLITS.items()
        for part in range(cols * rows)
    ]
    best = min(scores)
    print(f"{best[1]} {best[2]} {best[0]:.1f}")


if __name__ == "__main__":
    main()
