# ComicRedr

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Layout

```
lib/                      Flutter app (M2 shell: keyboard layer, Riverpod, Drift index)
packages/comic_formats    ComicDocument interface, magic-byte sniffing, natural sort
packages/comic_analysis   Panel model, reading order, the guided-view confidence gate
packages/reader_input     ReaderIntents, default keymap, vi key-sequence resolver
spike/                    M1 throwaway: classic-CV panel detection and overlays
test/corpus.manifest.toml Free test comics, fetched into git-ignored test/corpus/
```

## Develop

```sh
flutter pub get
dart run build_runner build -d   # regenerate Drift code after schema edits
flutter analyze && flutter test
for p in packages/*; do (cd $p && dart test); done
flutter run -d linux
```

## M1 detection spike

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics
python3 spike/make_synthetic.py                       # synthetic pages with ground truth
python3 spike/fetch_corpus.py                         # real comics + pretrained model
python3 spike/extract_pages.py test/corpus spike/pages
cd spike && python3 run_spike.py pages out --weights ../test/corpus/models/<model>.pt
```

`out/contact.jpg` shows every overlay: green boxes passed the confidence
gate, red ones fell back to plain paging, blue are the pretrained detector's
frames, magenta its balloons. Pages are sampled into one folder per style
(from the manifest's `style` field), `out/contact-<style>.jpg` puts classic
CV and the pretrained model side by side for each style, and `results.json`
carries a per-style summary.
