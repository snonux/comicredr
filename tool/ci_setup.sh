#!/usr/bin/env bash
# Installs what one CI job needs on a fresh Ubuntu runner, so the
# workflows stay thin and a change here needs no workflow edit.
#
#   tool/ci_setup.sh build    # Flutter's Linux build tools
#   tool/ci_setup.sh e2e      # what the tool/e2e_*.sh scripts drive the app with
#   tool/ci_setup.sh eval     # Python for spike/evaluate.py
#   tool/ci_setup.sh train    # Python for make train-model (CPU-only torch)
set -euo pipefail
apt() { sudo apt-get update -q && sudo apt-get install -y -q --no-install-recommends "$@"; }
pip() { python3 -m pip install --quiet --disable-pip-version-check "$@"; }
case "${1:?usage: tool/ci_setup.sh build|e2e|eval|train}" in
  build) apt clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev ;;
  e2e)
    apt libgtk-3-dev xvfb xdotool imagemagick sqlite3 openbox wmctrl x11-utils \
      zip unzip bc desktop-file-utils xdg-utils
    pip pillow numpy opencv-python-headless pypdfium2 ;;
  eval) pip opencv-python-headless numpy pillow pypdfium2 onnxruntime ;;
  train)
    pip torch --index-url https://download.pytorch.org/whl/cpu
    pip opencv-python-headless numpy pillow pypdfium2 transformers onnx onnxruntime onnxslim ;;
  *) echo "unknown job $1"; exit 2 ;;
esac
