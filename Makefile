# Build, run and install ComicRedr on Linux.
#
#   make                  release build into build/linux/x64/release/bundle/
#   make run [BOOK=path]  release build, then start it, optionally on a book
#   make dev              debug build with hot reload (flutter run -d linux)
#   make install          per-user install under ~/.local, no sudo
#   make uninstall        remove what make install put there
#   make tarball          release build packed as build/comicredr-VERSION-linux-ARCH.tar.gz
#   make keys             copy the default keymap to ~/.config/comicredr/keys.toml to edit
#   make fetch-model URL=url   download the detector model into the checkout
#   make train-model      rebuild the detector model from free comics (hours, CPU)
#   make model MODEL=path   put the detector model where the build packs it
#   make install-model MODEL=comicredr-panels.onnx   override it per user
#   make keystore         create the Android release key (once, back it up)
#   make apk              signed release APK for the phone (arm64)
#   make install-apk      sideload it over USB with adb
#   make push-model MODEL=comicredr-panels.onnx   override it on the phone
#   make push-keys        your keys.toml onto the phone
#   make test             flutter analyze + all tests
#   make analyze          flutter analyze only
#   make icons            re-render the PNG icons from the SVG
#   make clean            flutter clean
#   make version          print the app version from pubspec.yaml
#
# PREFIX=/usr/local (with sudo) installs system-wide; DESTDIR stages a
# package build.

APP_ID  := org.snonux.comicredr
FLUTTER ?= flutter
DART    ?= dart
PREFIX  ?= $(HOME)/.local
BOOK    ?=
MODEL   ?= comicredr-panels.onnx
URL     ?=
EPOCHS  ?= 45
# The detector model the build packs into the app (pubspec.yaml assets).
BUNDLED_MODEL := assets/models/comicredr-panels.onnx
# NO_MODEL=1 builds without it; the app then detects with classic CV.
NO_MODEL ?=
KEYS    ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/comicredr/keys.toml

ARCH := $(shell uname -m | sed -e 's/x86_64/x64/' -e 's/aarch64/arm64/')
BUNDLE := build/linux/$(ARCH)/release/bundle
PKG := linux/packaging

BINDIR  := $(PREFIX)/bin
LIBDIR  := $(PREFIX)/lib/comicredr
APPSDIR := $(PREFIX)/share/applications
ICONDIR := $(PREFIX)/share/icons/hicolor
ICON_SIZES := 16 24 32 48 64 128 256 512
MODELDIR ?= $(HOME)/.local/share/$(APP_ID)/models
# Android. The release key lives outside the repository: same-key signing is
# what lets a sideloaded update install over the old app and keep its data.
KEYSTORE ?= $(HOME)/.config/comicredr/release.jks
KEYPROPS := android/key.properties
APK_ABI  ?= android-arm64
APK      := build/app/outputs/flutter-apk/app-release.apk
ADB      ?= adb
PHONE_MODELDIR := /sdcard/Android/data/$(APP_ID)/files/models
ANDROID_ICONS := mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192

# pubspec.yaml's version without the +build suffix: 0.1.0+1 gives 0.1.0.
VERSION := $(shell sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
TARNAME := comicredr-$(VERSION)-linux-$(ARCH)
TARBALL := build/$(TARNAME).tar.gz

.PHONY: all build deps run dev test analyze install uninstall model fetch-model train-model install-model check-model icons clean help version \
	keystore apk install-apk push-model push-keys tarball keys

all: build

help:
	@sed -n '2,27p' Makefile | sed 's/^# \{0,1\}//'

version:
	@echo $(VERSION)

deps:
	$(FLUTTER) pub get

build: deps check-model
	$(FLUTTER) build linux --release

run: build
	$(BUNDLE)/comicredr $(if $(BOOK),"$(BOOK)")

dev: deps
	$(FLUTTER) run -d linux $(if $(BOOK),-a "$(BOOK)")

analyze: deps
	$(FLUTTER) analyze

test: analyze
	$(FLUTTER) test
	for p in packages/*; do (cd $$p && $(DART) test) || exit 1; done

# Install needs a finished build but does not start one, so that
# `sudo make install PREFIX=/usr/local` never runs Flutter as root.
install:
	@test -x $(BUNDLE)/comicredr || { echo "No release build yet: run make first."; exit 1; }
	@if [ -z "$(DESTDIR)" ]; then $(PKG)/keep-viewer.sh save build/viewer-defaults $(APPSDIR); fi
	rm -rf $(DESTDIR)$(LIBDIR)
	mkdir -p $(DESTDIR)$(LIBDIR) $(DESTDIR)$(BINDIR) $(DESTDIR)$(APPSDIR)
	cp -a $(BUNDLE)/. $(DESTDIR)$(LIBDIR)/
	ln -sfn $(LIBDIR)/comicredr $(DESTDIR)$(BINDIR)/comicredr
	sed 's|@BINDIR@|$(BINDIR)|g' $(PKG)/$(APP_ID).desktop.in > $(DESTDIR)$(APPSDIR)/$(APP_ID).desktop
	install -Dm644 $(PKG)/$(APP_ID).svg $(DESTDIR)$(ICONDIR)/scalable/apps/$(APP_ID).svg
	for s in $(ICON_SIZES); do \
	  install -Dm644 $(PKG)/icons/$${s}.png $(DESTDIR)$(ICONDIR)/$${s}x$${s}/apps/$(APP_ID).png || exit 1; \
	done
	$(MAKE) --no-print-directory _refresh
	@if [ -z "$(DESTDIR)" ]; then $(PKG)/keep-viewer.sh restore build/viewer-defaults $(APPSDIR); fi
	@echo "Installed. ComicRedr is in the app grid; $(BINDIR)/comicredr starts it from a shell."

uninstall:
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -f $(DESTDIR)$(BINDIR)/comicredr $(DESTDIR)$(APPSDIR)/$(APP_ID).desktop
	rm -f $(DESTDIR)$(ICONDIR)/scalable/apps/$(APP_ID).svg
	for s in $(ICON_SIZES); do rm -f $(DESTDIR)$(ICONDIR)/$${s}x$${s}/apps/$(APP_ID).png; done
	$(MAKE) --no-print-directory _refresh
	@echo "Uninstalled. Your reading progress and the model in ~/.local/share/$(APP_ID) are kept."

# Let GNOME pick up the launcher, the icon and the "Open with" entries
# straight away. Skipped when staging into DESTDIR; a package does it itself.
.PHONY: _refresh
_refresh:
ifeq ($(DESTDIR),)
	@if command -v update-desktop-database >/dev/null; then update-desktop-database -q $(APPSDIR) || true; fi
	@# A cache GNOME already has is refreshed; none is created, since a stale
	@# per-user cache would later hide other apps' icons.
	@if test -f $(ICONDIR)/icon-theme.cache; then gtk-update-icon-cache -qtf $(ICONDIR) || true; \
	 elif test -d $(ICONDIR); then touch $(ICONDIR); fi
endif

# The Linux release as one file to copy to another machine: unpack it, then
# run ./install.sh (into ~/.local) or start bundle/comicredr where it is.
tarball: build
	rm -rf build/tarball
	mkdir -p build/tarball/$(TARNAME)/packaging
	cp -a $(BUNDLE) build/tarball/$(TARNAME)/bundle
	cp -a $(PKG)/icons $(PKG)/$(APP_ID).desktop.in $(PKG)/$(APP_ID).svg $(PKG)/keep-viewer.sh build/tarball/$(TARNAME)/packaging/
	install -m755 $(PKG)/install.sh build/tarball/$(TARNAME)/install.sh
	cp README.md CHANGELOG.md docs/keys.toml build/tarball/$(TARNAME)/
	tar -C build/tarball -czf $(TARBALL) $(TARNAME)
	@echo "Built $(TARBALL)"

# Starts a keys.toml from the defaults; never overwrites one you have.
keys:
	@test ! -f "$(KEYS)" || { echo "$(KEYS) exists already; edit that one (docs/keys.toml has the defaults)."; exit 1; }
	install -Dm644 docs/keys.toml "$(KEYS)"
	@echo "Edit $(KEYS), keep only the lines you change, and restart ComicRedr."

# Every release build packs the model; stop early and say where it goes
# rather than ship an app that quietly falls back to classic CV.
check-model:
ifeq ($(NO_MODEL),)
	@test -s $(BUNDLED_MODEL) || { \
	  echo "No detector model at $(BUNDLED_MODEL)."; \
	  echo "Copy it there with: make model MODEL=/path/to/comicredr-panels.onnx"; \
	  echo "or build without it (classic CV only) with: make NO_MODEL=1"; exit 1; }
endif

fetch-model:
	@test -n "$(URL)" || { echo "Pass the model's location: make fetch-model URL=https://.../comicredr-panels.onnx (or a path)"; exit 1; }
	tool/fetch_model.sh "$(URL)"

# EPOCHS=1 for a quick run through the pipeline; 45 matches the shipped model.
train-model:
	EPOCHS=$(EPOCHS) tool/train_model.sh
	tool/fetch_model.sh spike/out/comicredr-panels.onnx

model:
	@test -f "$(MODEL)" || { echo "No model at $(MODEL); pass MODEL=/path/to/comicredr-panels.onnx"; exit 1; }
	install -Dm644 "$(MODEL)" $(BUNDLED_MODEL)
	@echo "Model in $(BUNDLED_MODEL); the next make packs it into the app."

# A model here wins over the one built into the app, for trying another
# model without rebuilding.
install-model:
	@test -f "$(MODEL)" || { echo "No model at $(MODEL); pass MODEL=/path/to/comicredr-panels.onnx"; exit 1; }
	install -Dm644 "$(MODEL)" $(MODELDIR)/comicredr-panels.onnx
	@echo "Model installed in $(MODELDIR). Restart ComicRedr to use it."

# One release key per person, made once. The password is random and kept in
# android/key.properties (gitignored); back up both files together.
keystore:
	@test ! -f "$(KEYSTORE)" || { echo "$(KEYSTORE) exists already; not replacing a release key."; exit 1; }
	mkdir -p "$(dir $(KEYSTORE))"
	@pw=$$(openssl rand -hex 16) && \
	keytool -genkeypair -noprompt -keystore "$(KEYSTORE)" -storetype PKCS12 \
	  -alias comicredr -keyalg RSA -keysize 4096 -validity 36500 \
	  -dname "CN=ComicRedr" -storepass "$$pw" -keypass "$$pw" && \
	chmod 600 "$(KEYSTORE)" && \
	printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=comicredr\nkeyPassword=%s\n' "$(KEYSTORE)" "$$pw" "$$pw" > $(KEYPROPS) && \
	chmod 600 $(KEYPROPS)
	@echo "Release key in $(KEYSTORE), password in $(KEYPROPS)."
	@echo "Back both up: an APK signed with another key cannot update the installed app."

apk: deps check-model
	@test -f $(KEYPROPS) || { echo "No release key: run make keystore once (or restore $(KEYPROPS) and the keystore)."; exit 1; }
	$(FLUTTER) build apk --release --target-platform $(APK_ABI)
	@echo "Built $(APK)"

install-apk:
	@test -f $(APK) || { echo "No APK yet: run make apk first."; exit 1; }
	$(ADB) install -r $(APK)

# adb may write into the app's folder on shared storage; most file managers
# on Android 11 and later may not.
push-model:
	@test -f "$(MODEL)" || { echo "No model at $(MODEL); pass MODEL=/path/to/comicredr-panels.onnx"; exit 1; }
	$(ADB) shell mkdir -p $(PHONE_MODELDIR)
	$(ADB) push "$(MODEL)" $(PHONE_MODELDIR)/comicredr-panels.onnx
	@echo "Model on the phone. Close and reopen ComicRedr to use it."

push-keys:
	@test -f "$(KEYS)" || { echo "No $(KEYS); run make keys first, or pass KEYS=/path/to/keys.toml"; exit 1; }
	$(ADB) shell mkdir -p $(dir $(PHONE_MODELDIR))
	$(ADB) push "$(KEYS)" $(dir $(PHONE_MODELDIR))keys.toml
	@echo "Keys on the phone. Close and reopen ComicRedr to use them."

# Re-render the committed PNG icons after editing the SVG.
# Needs rsvg-convert (dnf install librsvg2-tools).
icons:
	mkdir -p $(PKG)/icons
	for s in $(ICON_SIZES); do rsvg-convert -w $$s -h $$s $(PKG)/$(APP_ID).svg -o $(PKG)/icons/$$s.png || exit 1; done
	for d in $(ANDROID_ICONS); do \
	  rsvg-convert -w $${d#*:} -h $${d#*:} $(PKG)/$(APP_ID).svg \
	    -o android/app/src/main/res/mipmap-$${d%%:*}/ic_launcher.png || exit 1; \
	done

clean:
	$(FLUTTER) clean
