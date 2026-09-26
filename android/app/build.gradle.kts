import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key. Sideloaded updates only install over the old app, and
// keep its library and reading positions, when they are signed with the
// same key, so the keystore lives outside the repository and must be
// backed up. `make keystore` creates it and writes android/key.properties
// (gitignored) pointing at it; see the README.
val keyProperties =
    Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
val hasReleaseKey = keyProperties.getProperty("storeFile") != null

android {
    namespace = "org.snonux.comicredr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.snonux.comicredr"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Only the ABIs asked for (`--target-platform`, APK_ABI in the
        // Makefile). Plugins ship native libraries for others too
        // (armeabi-v7a), which made a 32-bit phone install an APK with no
        // Flutter engine for it, and cost 10 MB.
        (project.findProperty("target-platform") as String?)?.let { platforms ->
            val abis = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
            ndk {
                abiFilters.clear()
                abiFilters += platforms.split(",").mapNotNull { abis[it.trim()] }
            }
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without key.properties the release build falls back to the
            // debug key, so `flutter run --release` and test builds still
            // work; `make apk` refuses to build that way.
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
