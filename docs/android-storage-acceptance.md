# Android storage acceptance

Task q43 checks real shared paths through the app UI, using a locally built
release APK. Widget tests cover the explanation and cancellation, but do not
establish Android filesystem access.

## Build and devices

Checked on 2026-10-04, from `a3ba6cc` plus the q43 storage guidance change:
`make apk APK_ABI=android-arm64,android-x64`. The APK reports 0.6.0, build 8,
minimum SDK 24 and target SDK 36; it includes the bundled detector. SHA-256:

```
d652bb24e5f546f0e607c1f5901b075fdf646e97cb580d60516fcc82b9ed9429
```

Android Emulator 33.1.24 used KVM and SwiftShader on separate disposable
`ComicRedr_Acceptance_API28`, `API29` and `API34` AVDs. Existing Quicklog,
Player and personal AVDs were left alone. The activity was launched with
`--ez enable-impeller false`; the source manifest was not changed.

| OS | Image fingerprint |
|---|---|
| Android 9 / API 28 | `Android/sdk_phone_x86_64/generic_x86_64:9/PSR1.180720.012/4923214:userdebug/test-keys` |
| Android 10 / API 29 | `Android/sdk_phone_x86_64/generic_x86_64:10/QSR1.210820.001/7663313:userdebug/test-keys` |
| Android 14 / API 34 | `google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036.A1/11228894:userdebug/dev-keys` |

## Procedure and evidence

Run `python3 tool/e2e_android_storage.py SERIAL APK` on a fully booted dedicated
AVD. The harness refuses other AVD names before clearing ComicRedr's data.
It makes three disposable JPEG CBZs, one in `Comics` and one each under
`Download/ComicRedrAcceptance` and `Documents/ComicRedrAcceptance`.

Before granting shared storage, the app creates its private SQLite index and
opens the empty library. **Not now** leaves access ungranted. On API 28/29,
**Allow access** opens Android's runtime dialog: deny, retry, then allow.
On API 34, **Open settings** opens All files access: return without granting,
retry, then enable the switch.

The permission return adds and scans the default Comics folder. To distinguish
this from launch-time discovery, the harness stops the app and inspects its
already-written private index before launching again. On API 29, appops reports
`LEGACY_STORAGE: allow`; actual reading, sidecar writes, export and deletion
establish shared-path behavior for the target-SDK-36 APK.

Each book is opened from the library, the first page displayed, and advanced
to page 2. Screenshot assertions check a red marker on page 1 and a green
marker on page 2, so a decode failure or stale image cannot pass just because
the page counter changed. Its sidecar must contain page index 1. Settings
exports all three sidecars to a cleared fixture folder under Documents;
the exported device, page and update-time rows must match this run's sidecars.
Every deletion is first cancelled,
checking that the original remains, then confirmed; both original and adjacent
sidecar must disappear. The books are fixtures; no personal comics are touched.

Artifacts are in `build/e2e-android-storage/`: per-OS logs, screenshots, UI dumps,
permission dumps, the index captured after granting access, and the three
sidecars. Guide permission screenshots come from this release build, following
the manual Android capture procedure documented in `tool/guide_shots.sh`.

## Results

The final harness passed on all three images, including its rendered-page
and fresh-export assertions:

| Check | API 28 | API 29 | API 34 |
|---|---|---|---|
| Private index before permission; cancel explanation | Pass | Pass | Pass |
| Deny or return without granting; retry and grant | Pass | Pass | Pass |
| Grant return adds and scans Comics before a restart | Pass | Pass | Pass |
| Comics, Download, Documents: render pages 1 and 2 | Pass | Pass | Pass |
| Adjacent sidecars record page 2; fresh export matches | Pass | Pass | Pass |
| Cancel deletion; then delete original and sidecar | Pass | Pass | Pass |

The OS-specific explanation has seven passing widget tests, including
existing access, denial/retry, cancellation, null/error responses and disposal.
`make test` passed with the emulators stopped: analysis and formatting,
all 289 app tests and all four package suites. The formats suite also passed
the real unreadable-folder assertion as a non-root user (task 553).
Four live S3 integration tests were skipped by their existing guard because
`GARAGE_TEST_ENDPOINT` was unset; S3 code was not changed by these tasks.

Android 7 and 8 individually, physical phones/tablets, removable volumes,
third-party document providers and the permanent-denial system Settings route
were not tested. The matrix concerns storage access, not touch performance or
memory behavior on physical devices.
