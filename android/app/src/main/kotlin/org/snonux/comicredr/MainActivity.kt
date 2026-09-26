package org.snonux.comicredr

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
                        if (!hasAccess() && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            // A dialog, not a settings page; the library
                            // looks again on resume, as after the page.
                            requestPermissions(STORAGE, PERMISSIONS)
                        } else if (!hasAccess()) {
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
                    // The system picker, answered with the file's real path
                    // rather than a copy: the reader keeps its sidecar, its
                    // history and Delete on the comic itself.
                    "pickFile" -> pick(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }, result)
                    "pickFolder" -> pick(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), result)
                    else -> result.notImplemented()
                }
            }
    }

    private var picking: MethodChannel.Result? = null

    private fun pick(intent: Intent, result: MethodChannel.Result) {
        if (picking != null) {
            result.success(null)
            return
        }
        picking = result
        try {
            startActivityForResult(intent, PICK)
        } catch (e: Exception) {
            picking = null
            result.error("unavailable", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = picking ?: return
        picking = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val path = pathOf(uri)
        if (path == null) result.error("no-path", uri.toString(), null) else result.success(path)
    }

    /// Where a picked document or folder is on the phone's storage, or null
    /// for one that has no path there (a cloud drive, another app's files).
    private fun pathOf(uri: Uri): String? {
        val id = try {
            if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(this, uri)) {
                DocumentsContract.getTreeDocumentId(uri)
            } else {
                DocumentsContract.getDocumentId(uri)
            }
        } catch (e: Exception) {
            null
        }
        val path = when {
            uri.scheme == "file" -> uri.path
            id == null -> dataColumn(uri, null, null)
            uri.authority == "com.android.externalstorage.documents" -> {
                val volume = id.substringBefore(':')
                val rest = id.substringAfter(':', "")
                val root = if (volume == "primary") Environment.getExternalStorageDirectory().path else "/storage/$volume"
                if (rest.isEmpty()) root else "$root/$rest"
            }
            uri.authority == "com.android.providers.downloads.documents" && id.startsWith("raw:") -> id.removePrefix("raw:")
            uri.authority == "com.android.providers.downloads.documents" || uri.authority == "com.android.providers.media.documents" ->
                id.substringAfter(':').toLongOrNull()?.let {
                    dataColumn(MediaStore.Files.getContentUri("external"), "_id=?", arrayOf(it.toString()))
                } ?: dataColumn(uri, null, null)
            else -> dataColumn(uri, null, null)
        }
        return path?.takeIf { File(it).canRead() }
    }

    private fun dataColumn(uri: Uri, selection: String?, args: Array<String>?): String? = try {
        contentResolver.query(uri, arrayOf("_data"), selection, args, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            STORAGE.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        }

    companion object {
        private const val PICK = 4817
        private const val PERMISSIONS = 4818
        private val STORAGE = arrayOf(
            android.Manifest.permission.READ_EXTERNAL_STORAGE,
            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
        )
    }
}
