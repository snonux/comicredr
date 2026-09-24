package org.snonux.comicredr

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// All-files access (MANAGE_EXTERNAL_STORAGE), so the library reads real
/// paths such as /storage/emulated/0/Comics (design plan section 8). It is
/// granted once, on a system settings page rather than in a dialog.
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Android sets no HOME and its default TMPDIR (/data/local/tmp) is
        // not the app's to write. Dart code that falls back on them, like
        // pdfrx picking its cache folder, fails with a null check, so
        // every PDF was unreadable. Point both at the app's own folders
        // before the Flutter engine, and so every Dart isolate, starts.
        Os.setenv("HOME", filesDir.absolutePath, false)
        Os.setenv("TMPDIR", cacheDir.absolutePath, true)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.snonux.comicredr/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAccess())
                    "requestAllFilesAccess" -> {
                        if (!hasAccess() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName"),
                            )
                            try {
                                startActivity(intent)
                            } catch (e: Exception) {
                                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true
}
