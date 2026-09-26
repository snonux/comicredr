# Installing ComicRedr on Android

ComicRedr is a sideloaded app: it is not in Google Play. There are two
ways to get it onto a phone.

## From F-Droid

The easiest way is snonux's own F-Droid repository,
[snonux/fdroid](https://github.com/snonux/fdroid), which also brings
updates.

1. Install the [F-Droid](https://f-droid.org) app on the phone.
2. Add the repository: open
   [this link](https://fdroid.link/#https://snonux.github.io/fdroid/repo?fingerprint=04B05FB0565543E058372B867B3D3A699D9D668388CE670478EDD4116D736DF7)
   on the phone, or in F-Droid go to *Settings → Repositories → +* and
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

Turn on **USB debugging** on the phone, plug it in, and from the checkout:

```sh
make keystore       # once: creates your signing key
make apk            # build the APK
make install-apk    # install it, keeping the app's data
```

The APK carries the same built-in panel detector.

> **Back up `~/.config/comicredr/release.jks` and `android/key.properties`.**
> Android only installs an update over the old app, keeping your library
> and positions, when it is signed with the same key. On a new laptop,
> restore both files instead of running `make keystore` again.

What to do on the phone the first time is in
[On the phone](guide/10-phone.md#first-start) in the guide.

Pick one way and stay with it. Android only updates an app with an APK
signed by the same key, so an APK signed with your own key and the one
from F-Droid can't replace each other without uninstalling first, which
loses the app's library, settings and history (the sidecars beside your
comics, with positions and bookmarks, stay).

## Another detector model

`make push-model MODEL=file.onnx` copies another model to the phone over
USB, where it wins over the built-in one until the next
`make install-apk`. See [Another detector model](install-linux.md#another-detector-model).
