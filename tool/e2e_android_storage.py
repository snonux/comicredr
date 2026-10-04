#!/usr/bin/env python3
"""Release APK storage acceptance on a disposable ComicRedr_Acceptance_* AVD.

Build with make apk APK_ABI=android-arm64,android-x64. Boot one dedicated
AVD fully, then run: python3 tool/e2e_android_storage.py SERIAL APK
Needs adb, Pillow, a rooted AOSP/Google APIs image, and Android API 28/29/34.
Clears only ComicRedr on that dedicated AVD; never use a personal device.
Screenshots, UI dumps, private index and sidecars go in build/e2e-android-storage/.
"""

import argparse
import io
import re
import shlex
import sqlite3
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw

PKG = "org.snonux.comicredr"


class Device:
    def __init__(self, serial, out):
        self.serial = serial
        self.out = out

    def adb(self, *args, binary=False):
        return subprocess.check_output(["adb", "-s", self.serial, *args], text=not binary)

    def shell(self, *args):
        return self.adb("shell", shlex.join(args)).strip()

    def shot(self, name):
        (self.out / f"{name}.png").write_bytes(self.adb("exec-out", "screencap", "-p", binary=True))

    def nodes(self):
        for _ in range(3):
            self.shell("rm", "-f", "/sdcard/comicredr-ui.xml")
            self.shell("uiautomator", "dump", "/sdcard/comicredr-ui.xml")
            if self.exists("/sdcard/comicredr-ui.xml"):
                xml = self.shell("cat", "/sdcard/comicredr-ui.xml")
                (self.out / "latest-ui.xml").write_text(xml)
                return list(ET.fromstring(xml).iter("node"))
            time.sleep(1)
        raise RuntimeError("uiautomator returned no current UI hierarchy")

    def find(self, pattern, exclude_text_fields=False):
        return next(
            (
                n for n in self.nodes()
                if not (exclude_text_fields and n.get("class") == "android.widget.EditText")
                and any(re.fullmatch(pattern, n.get(k, ""), re.DOTALL) for k in ("text", "content-desc"))
            ),
            None,
        )

    def tap(self, pattern, scroll=False, exclude_text_fields=False):
        for _ in range(12 if scroll else 4):
            node = self.find(pattern, exclude_text_fields)
            if node is not None:
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
                self.shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
                time.sleep(1)
                return
            if scroll:
                self.shell("input", "swipe", "540", "1400", "540", "600", "400")
            time.sleep(1)
        self.shot("missing-target")
        raise AssertionError(f"UI target absent: {pattern}")

    def wait(self, pattern):
        for _ in range(8):
            if self.find(pattern) is not None:
                return
            time.sleep(1)
        self.shot("missing-state")
        raise AssertionError(f"UI state absent: {pattern}")

    def open_book(self, name, page=1):
        self.text("/")
        self.text(name)
        self.key("KEYCODE_ENTER")
        self.tap(re.escape(name), exclude_text_fields=True)
        self.tap("Read|Read again|Continue reading")
        self.wait(rf".*(?:page {page} / 3|Resumed at page {page}).*")

    def rendered_page(self, title, page):
        # A page counter can advance even when decoding fails or old pixels
        # remain. Every fixture page has a different large RGB marker.
        for _ in range(10):
            name = f"05-read-{title}-page-{page}"
            self.shot(name)
            with Image.open(self.out / f"{name}.png") as screenshot:
                width, height = screenshot.size
                pixels = screenshot.convert("RGB").crop(
                    (width // 4, height * 2 // 5, width * 3 // 4, height * 4 // 5)
                )
                channel = page - 1
                marked = sum(
                    rgb[channel] > 200 and all(rgb[i] < 70 for i in range(3) if i != channel)
                    for rgb in pixels.getdata()
                )
                if marked > 250:
                    check(f"{title}: page {page} fixture pixels rendered", True)
                    return
            time.sleep(1)
        raise AssertionError(f"{title}: page {page} fixture pixels absent")

    def key(self, *keys):
        self.shell("input", "keyevent", *keys)
        time.sleep(1)

    def text(self, value):
        self.shell("input", "text", value)
        time.sleep(0.5)

    def field(self, value):
        # Every path field starts focused with a suggested shared directory.
        self.key("KEYCODE_MOVE_END", *(["KEYCODE_DEL"] * 120))
        self.text(value)
        self.key("KEYCODE_BACK")  # hide the IME, leaving the dialog open

    def exists(self, path):
        return self.shell("sh", "-c", f"test -e {shlex.quote(path)} && echo yes || echo no") == "yes"

    def launch(self):
        self.shell("am", "start", "-W", "-n", f"{PKG}/.MainActivity", "--ez", "enable-impeller", "false")
        time.sleep(5)
        for _ in range(12):
            try:
                if self.find("Settings") is not None:
                    return
            except RuntimeError:
                pass  # A cold Flutter start may still be on Android's splash.
            time.sleep(1)
        self.shot("startup-not-ready")
        raise AssertionError("library UI did not finish starting")

    def copy(self, remote, name):
        local = self.out / name
        local.write_bytes(self.adb("exec-out", "cat", remote, binary=True))
        return local


def check(what, condition):
    if not condition:
        raise AssertionError(what)
    print(f"PASS {what}", flush=True)


def fixtures(out):
    books = []
    for title in ("Comics", "Download", "Documents"):
        path = out / f"Storage{title}.cbz"
        with zipfile.ZipFile(path, "w") as archive:
            for page in range(1, 4):
                image = Image.new("RGB", (600, 900), "ivory")
                draw = ImageDraw.Draw(image)
                draw.rectangle((30, 30, 570, 870), outline="black", width=6)
                draw.text((80, 200), f"Storage {title} page {page}", fill="black", font_size=30)
                draw.rectangle((240, 540, 360, 660), fill=("red", "lime", "blue")[page - 1])
                data = io.BytesIO()
                image.save(data, "JPEG")
                archive.writestr(f"{page:02}.jpg", data.getvalue())
        books.append((title, path))
    return books


def run(serial, apk):
    avd = subprocess.check_output(["adb", "-s", serial, "emu", "avd", "name"], text=True).splitlines()[0]
    if not avd.startswith("ComicRedr_Acceptance_"):
        raise RuntimeError("Refusing to clear app data outside a dedicated ComicRedr_Acceptance_* AVD")
    out = Path("build/e2e-android-storage") / avd
    out.mkdir(parents=True, exist_ok=True)
    d = Device(serial, out)
    check("emulator fully booted", d.shell("getprop", "sys.boot_completed") == "1")
    api = int(d.shell("getprop", "ro.build.version.sdk"))
    check("supported acceptance OS", api in (28, 29, 34))
    (out / "fingerprint.txt").write_text(d.shell("getprop", "ro.build.fingerprint") + "\n")
    d.adb("root")
    d.adb("wait-for-device")
    d.adb("install", "-r", str(apk))
    d.shell("pm", "clear", PKG)
    if api >= 30:
        d.shell("appops", "set", "--uid", PKG, "MANAGE_EXTERNAL_STORAGE", "default")
    d.shell("settings", "put", "system", "screen_off_timeout", "1800000")
    d.key("KEYCODE_WAKEUP", "KEYCODE_MENU")
    books = fixtures(out)
    for title, path in books:
        root = f"/sdcard/{title}" if title == "Comics" else f"/sdcard/{title}/ComicRedrAcceptance"
        d.shell("mkdir", "-p", root)
        d.shell("rm", "-f", f"{root}/.{path.name}.crdb")
        d.adb("push", str(path), f"{root}/{path.name}")

    d.launch()
    d.shot("01-private-data-no-permission")
    # Application support uses the app's private files directory.
    index_path = f"/data/user/0/{PKG}/files/comicredr.sqlite"
    check("private index exists without shared access", d.exists(index_path))
    (out / "permissions-before.txt").write_text(d.shell("dumpsys", "package", PKG))
    check("no startup permission dialog", d.find("Allow access to your comics") is None)
    d.tap("Add your comics folder|Add a folder to the library.*")
    d.shot("02-storage-explanation")
    action = "Open settings" if api >= 30 else "Allow access"
    check("OS-specific action", d.find(action) is not None)
    d.tap("Not now")
    d.tap("Add your comics folder|Add a folder to the library.*")
    d.tap(action)
    d.shot("03-system-permission")
    if api < 30:
        d.tap("DENY|Deny")
        d.tap("Add your comics folder|Add a folder to the library.*")
        check("denial keeps access explanation", d.find("Allow access to your comics") is not None)
        d.tap("Allow access")
        d.tap("ALLOW|Allow")
    else:
        check("All files access settings opened", "com.android.settings" in d.shell("dumpsys", "activity", "activities"))
        d.key("KEYCODE_BACK")
        d.tap("Add your comics folder|Add a folder to the library.*")
        check("return without granting keeps access explanation", d.find("Allow access to your comics") is not None)
        d.tap("Open settings")
        d.tap("Allow access to manage all files")
        d.key("KEYCODE_BACK")
    time.sleep(5)
    (out / "permissions-after.txt").write_text(d.shell("dumpsys", "package", PKG))
    if api == 29:
        legacy = d.shell("cmd", "appops", "get", PKG, "LEGACY_STORAGE")
        (out / "legacy-storage.txt").write_text(legacy + "\n")
    d.shot("04-granted-default-library")
    # No app restart or explicit rescan: the permission return must add Comics.
    d.shell("am", "force-stop", PKG)
    index = d.copy(index_path, "after-grant.sqlite")
    for suffix in ("-wal", "-shm"):
        Path(str(index) + suffix).unlink(missing_ok=True)
        if d.exists(index_path + suffix):
            d.copy(index_path + suffix, index.name + suffix)
    with sqlite3.connect(index) as db:
        check("grant return adds default Comics without restart", db.execute("select count(*) from roots").fetchone()[0] == 1)
        check("default comic scanned", db.execute("select count(*) from books").fetchone()[0] == 1)
    d.launch()

    progress = []
    for title, path in books:
        if title != "Comics":
            d.tap("Add your comics folder|Add a folder to the library.*")
            d.field(f"/storage/emulated/0/{title}/ComicRedrAcceptance")
            d.tap("Add")
            time.sleep(3)
        d.open_book(path.stem)
        d.rendered_page(title, 1)
        d.text("l")
        d.wait(r".*page 2 / 3.*")
        d.rendered_page(title, 2)
        d.key("KEYCODE_BACK")
        time.sleep(3)
        root = f"/sdcard/{title}" if title == "Comics" else f"/sdcard/{title}/ComicRedrAcceptance"
        sidecar = f"{root}/.{path.name}.crdb"
        check(f"{title}: sidecar written beside original", d.exists(sidecar))
        local = d.copy(sidecar, f"sidecar-{title}.sqlite")
        with sqlite3.connect(local) as db:
            check(f"{title}: reading progress written", db.execute("select max(page) from progress").fetchone()[0] == 1)
            progress.extend(db.execute("select device, page, updated_at from progress").fetchall())
        d.key("KEYCODE_ESCAPE")  # leave details/search
        d.key("KEYCODE_ESCAPE")

    export_dir = "/sdcard/Documents/ComicRedrAcceptance/Export"
    d.shell("rm", "-rf", export_dir)  # only this dedicated fixture destination
    check("export destination starts absent", not d.exists(export_dir))
    d.tap("Settings")
    d.tap("Export sidecars to a folder…", scroll=True)
    d.field("/storage/emulated/0/Documents/ComicRedrAcceptance/Export")
    d.tap("Export")
    time.sleep(3)
    exported = d.shell("find", export_dir, "-name", "*.crdb")
    check("all three sidecars exported to shared Documents", len(exported.splitlines()) == 3)
    exported_progress = []
    for i, remote in enumerate(exported.splitlines()):
        with sqlite3.connect(d.copy(remote, f"export-{i}.sqlite")) as db:
            exported_progress.extend(db.execute("select device, page, updated_at from progress").fetchall())
    check("exported progress matches this run's sidecars", sorted(exported_progress) == sorted(progress))
    d.shot("06-exported")

    for title, path in books:
        # This book resumes on page 2 after the earlier read.
        d.open_book(path.stem, page=2)
        d.text("gd")
        d.tap("Cancel")
        root = f"/sdcard/{title}" if title == "Comics" else f"/sdcard/{title}/ComicRedrAcceptance"
        check(f"{title}: cancelled deletion keeps original", d.exists(f"{root}/{path.name}"))
        d.text("gd")
        d.shot(f"07-delete-{title}")
        d.tap("Delete for good")
        check(f"{title}: original deleted", not d.exists(f"{root}/{path.name}"))
        check(f"{title}: sidecar deleted", not d.exists(f"{root}/.{path.name}.crdb"))
        d.key("KEYCODE_ESCAPE")
        d.key("KEYCODE_ESCAPE")
    print(f"PASS Android API {api} storage acceptance", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    run(args.serial, args.apk)
