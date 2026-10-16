"""Auto-trim: the Python twin of packages/comic_analysis/lib/src/trim.dart.

Finds a scanned page's blank margins from its luminance profile, on a copy
240 px wide (as the app measures it). Returns (left, top, right, bottom) as
fractions of the page; (0, 0, 1, 1) means nothing to trim. The constants and
rules match the Dart file; see it for the reasoning.
"""
import math

import cv2
import numpy as np

FULL = (0.0, 0.0, 1.0, 1.0)
# The margin left around the art when a page is trimmed for detection.
DETECT_PAD = 0.03
# Pages are only trimmed for detection when what is left is at most this
# share of the page: the margins are wide enough to hide the layout.
DETECT_BELOW = 0.8
MEASURE_WIDTH = 240


def find_trim(img, tolerance=40, ink=0.015, max_trim=0.2, pad=0.01):
    """[img] is a BGR page of any size."""
    h0, w0 = img.shape[:2]
    w = MEASURE_WIDTH
    h = max(16, round(h0 * w / w0))
    small = cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA).astype(np.int32)
    b, g, r = small[:, :, 0], small[:, :, 1], small[:, :, 2]
    lum = (r * 299 + g * 587 + b * 114) // 1000
    paper = _edge_mode(lum)
    content = np.abs(lum - paper) > tolerance
    rows = content.sum(axis=1) > w * ink
    cols = content.sum(axis=0) > h * ink
    top, bottom = _first_run(rows, True), _first_run(rows, False)
    left, right = _first_run(cols, True), _first_run(cols, False)
    if None in (top, bottom, left, right):
        return FULL

    def cut(edge, size):
        return min(max(edge / size - pad, 0.0), max_trim)

    t = (cut(left, w), cut(top, h), 1 - cut(w - 1 - right, w), 1 - cut(h - 1 - bottom, h))
    worth = t[0] >= 0.01 or t[1] >= 0.01 or 1 - t[2] >= 0.01 or 1 - t[3] >= 0.01
    return t if worth and t[2] - t[0] > 0.3 and t[3] - t[1] > 0.3 else FULL


def detection_trim(img, pad=DETECT_PAD, below=DETECT_BELOW):
    """The trim panel detection runs on, as PanelDetector does: FULL unless
    the margins are wide."""
    t = find_trim(img, pad=pad)
    return t if (t[2] - t[0]) * (t[3] - t[1]) <= below else FULL


def _first_run(lines, forward):
    need = max(2, math.ceil(len(lines) * 0.01))
    run = 0
    n = len(lines)
    for k in range(n):
        i = k if forward else n - 1 - k
        if lines[i]:
            run += 1
            if run >= need:
                return i - run + 1 if forward else i + run - 1
        else:
            run = 0
    return None


def _edge_mode(lum):
    h, w = lum.shape
    hist = np.zeros(32, np.int64)
    step = min(w, h) * 0.01
    for r in range(4):
        k = math.floor(r * step)
        for line in (lum[k, k:w - k], lum[h - 1 - k, k:w - k], lum[k + 1:h - 1 - k, k], lum[k + 1:h - 1 - k, w - 1 - k]):
            hist += np.bincount(line >> 3, minlength=32)
    return int(np.argmax(hist)) * 8 + 4


def crop(img, t):
    """The trimmed part of [img], in whole pixels, and the trim it really is."""
    h, w = img.shape[:2]
    x0, y0 = round(t[0] * w), round(t[1] * h)
    x1, y1 = round(t[2] * w), round(t[3] * h)
    return img[y0:y1, x0:x1], (x0 / w, y0 / h, x1 / w, y1 / h)


def to_page(boxes, t):
    """Boxes [x, y, w, h] normalised to the crop, back onto the page."""
    tw, th = t[2] - t[0], t[3] - t[1]
    return [[t[0] + x * tw, t[1] + y * th, w * tw, h * th] for x, y, w, h in boxes]


def to_crop(boxes, t):
    """Boxes [x, y, w, h] normalised to the page, onto the crop."""
    tw, th = t[2] - t[0], t[3] - t[1]
    return [[(x - t[0]) / tw, (y - t[1]) / th, w / tw, h / th] for x, y, w, h in boxes]
