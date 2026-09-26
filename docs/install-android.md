# Installing ComicRedr on Android

ComicRedr is a sideloaded app: it is not in Google Play. There are two
ways to get it onto a phone or tablet; both are the same app, which lays
itself out for the screen it is on.

## From F-Droid

The easiest way is snonux's own F-Droid repository,
[snonux/fdroid](https://github.com/snonux/fdroid). It serves the signed
APK of each tagged ComicRedr release, for arm64 phones and tablets
(almost every one sold since 2017), and F-Droid then keeps the app
updated.

1. Install the [F-Droid](https://f-droid.org) app on the phone or tablet.
2. Add the repository: open
   [this link](https://fdroid.link/#https://snonux.github.io/fdroid/repo?fingerprint=04B05FB0565543E058372B867B3D3A699D9D668388CE670478EDD4116D736DF7)
   on the phone or tablet, or in F-Droid go to *Settings → Repositories → +* and
   enter
   - Address: `https://snonux.github.io/fdroid/repo`
   - Fingerprint: `04B05FB0565543E058372B867B3D3A699D9D668388CE670478EDD4116D736DF7`
3. Search for ComicRedr in F-Droid and install it.

The repository's [README](https://github.com/snonux/fdroid#add-the-repo-on-a-phone)
also has a QR code to scan instead of the link.

## Build the APK yourself

If you would rather not use F-Droid, build the APK on a Linux laptop and
install it over USB. On top of the
[Linux build setup](install-linux.md#build-tools-and-flutter), you need
a JDK and the Android command-line tools:

```sh
sudo dnf install java-21-openjdk-devel android-tools
mkdir -p ~/Android/Sdk/cmdline-tools && cd ~/Android/Sdk/cmdline-tools
curl -LO https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip commandlinetools-linux-*_latest.zip && mv cmdline-tools latest
export ANDROID_HOME=~/Android/Sdk   # put this in ~/.bashrc too
~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager "platform-tools"
flutter config --android-sdk ~/Android/Sdk
flutter doctor --android-licenses
```

Turn on **USB debugging** on the phone or tablet, plug it in, and from
the checkout:

```sh
make keystore       # once: creates your signing key
make apk            # build the APK
make install-apk    # install it, keeping the app's data
```

The APK carries the same built-in panel detector. It is built for arm64
only; an older tablet with a 32-bit ARM processor, or an x86_64 one, is
not supported (`make apk APK_ABI=android-arm64,android-x64` adds x86_64,
for the emulator; see AGENTS.md).

> **Back up `~/.config/comicredr/release.jks` and `android/key.properties`.**
> Android only installs an update over the old app, keeping your library
> and positions, when it is signed with the same key. On a new laptop,
> restore both files instead of running `make keystore` again.
> Built with the project's own release key, an APK and the F-Droid one
> update each other.

What to do on the device the first time is in
[On a phone or tablet](guide/10-phone.md#first-start) in the guide.

The F-Droid APKs are signed with the project's release key. Android only
updates an app with an APK signed by the same key, so an APK you build
with a key of your own (`make keystore`) and the one from F-Droid can't
replace each other: switching means uninstalling first, which loses the
app's library, settings and history (the sidecars beside your comics,
with positions and bookmarks, stay). Pick one way and stay with it.

## Another detector model

`make push-model MODEL=file.onnx` copies another model to the device over
USB, where it wins over the built-in one until the next
`make install-apk`. See [Another detector model](install-linux.md#another-detector-model).
