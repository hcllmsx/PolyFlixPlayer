package com.polyflix.polyflix_player

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.polyflix.player/storage_permission"
    private val REQUEST_CODE_PICK_VIDEOS = 2002
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasStoragePermission" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                    } else {
                        true
                    }
                    result.success(granted)
                }
                "requestStoragePermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            startActivity(intent)
                            result.success(true)
                        }
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        requestPermissions(
                            arrayOf(
                                Manifest.permission.READ_EXTERNAL_STORAGE,
                                Manifest.permission.WRITE_EXTERNAL_STORAGE
                            ),
                            1001
                        )
                        result.success(true)
                    } else {
                        result.success(true)
                    }
                }
                "pickVideoFiles" -> {
                    if (pendingPickResult != null) {
                        pendingPickResult?.error("ALREADY_ACTIVE", "Another pick operation is in progress", null)
                        pendingPickResult = null
                    }
                    pendingPickResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "application/octet-stream", "*/*"))
                        }
                        startActivityForResult(intent, REQUEST_CODE_PICK_VIDEOS)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            }
                            startActivityForResult(intent, REQUEST_CODE_PICK_VIDEOS)
                        } catch (ex: Exception) {
                            pendingPickResult?.error("LAUNCH_FAILED", ex.message, null)
                            pendingPickResult = null
                        }
                    }
                }
                "getCacheSize" -> {
                    val totalBytes = calculateCacheSize(this)
                    result.success(totalBytes)
                }
                "clearCache" -> {
                    val clearedBytes = clearAppCache(this)
                    result.success(clearedBytes)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_VIDEOS) {
            val res = pendingPickResult ?: return
            pendingPickResult = null

            if (resultCode != Activity.RESULT_OK || data == null) {
                res.success(emptyList<Map<String, String>>())
                return
            }

            val uris = mutableListOf<Uri>()
            data.clipData?.let { clipData ->
                for (i in 0 until clipData.itemCount) {
                    uris.add(clipData.getItemAt(i).uri)
                }
            } ?: data.data?.let { uri ->
                uris.add(uri)
            }

            val results = mutableListOf<Map<String, String>>()
            for (uri in uris) {
                val realPath = UriUtils.getPath(this, uri)
                val fileName = UriUtils.getFileName(this, uri, realPath)
                if (realPath != null && File(realPath).exists()) {
                    results.add(mapOf("path" to realPath, "name" to fileName))
                } else {
                    // Fallback to file_picker style only if real path cannot be resolved
                    val copyPath = UriUtils.copyToCacheIfNeeded(this, uri, fileName)
                    if (copyPath != null) {
                        results.add(mapOf("path" to copyPath, "name" to fileName))
                    }
                }
            }
            res.success(results)
        }
    }

    private fun calculateCacheSize(context: Context): Long {
        var size: Long = 0
        context.cacheDir?.let { size += getFolderSize(it) }
        context.externalCacheDir?.let { size += getFolderSize(it) }
        context.codeCacheDir?.let { size += getFolderSize(it) }
        return size
    }

    private fun getFolderSize(file: File): Long {
        var size: Long = 0
        try {
            if (file.isDirectory) {
                file.listFiles()?.forEach { child ->
                    size += getFolderSize(child)
                }
            } else {
                size += file.length()
            }
        } catch (_: Exception) {}
        return size
    }

    private fun clearAppCache(context: Context): Long {
        val before = calculateCacheSize(context)
        context.cacheDir?.deleteRecursivelySafe()
        context.externalCacheDir?.deleteRecursivelySafe()
        return before
    }

    private fun File.deleteRecursivelySafe() {
        try {
            if (isDirectory) {
                listFiles()?.forEach { it.deleteRecursivelySafe() }
            }
            delete()
        } catch (_: Exception) {}
    }
}

object UriUtils {
    fun getPath(context: Context, uri: Uri): String? {
        if (uri.scheme.equals("file", ignoreCase = true)) {
            return uri.path
        }

        if (DocumentsContract.isDocumentUri(context, uri)) {
            val docId = DocumentsContract.getDocumentId(uri)

            // ExternalStorageProvider
            if (isExternalStorageDocument(uri)) {
                val split = docId.split(":")
                val type = split[0]
                if ("primary".equals(type, ignoreCase = true)) {
                    val rel = if (split.size > 1) split[1] else ""
                    return "${Environment.getExternalStorageDirectory()}/$rel"
                } else {
                    val rel = if (split.size > 1) split[1] else ""
                    val path = "/storage/$type/$rel"
                    if (File(path).exists()) return path
                    return "/storage/emulated/0/$rel"
                }
            }

            // DownloadsProvider
            if (isDownloadsDocument(uri)) {
                if (docId.startsWith("raw:")) {
                    return docId.removePrefix("raw:")
                }
                try {
                    val contentUri = ContentUris.withAppendedId(
                        Uri.parse("content://downloads/public_downloads"),
                        docId.toLong()
                    )
                    getDataColumn(context, contentUri, null, null)?.let { return it }
                } catch (_: Exception) {}
            }

            // MediaProvider
            if (isMediaDocument(uri)) {
                val split = docId.split(":")
                val type = split[0]
                val contentUri: Uri = when (type) {
                    "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    else -> MediaStore.Files.getContentUri("external")
                }
                val selection = "_id=?"
                val selectionArgs = arrayOf(if (split.size > 1) split[1] else docId)
                return getDataColumn(context, contentUri, selection, selectionArgs)
            }
        }

        // MediaStore (and general)
        if ("content".equals(uri.scheme, ignoreCase = true)) {
            if (isGooglePhotosUri(uri)) return uri.lastPathSegment
            return getDataColumn(context, uri, null, null)
        }

        return null
    }

    private fun getDataColumn(
        context: Context,
        uri: Uri,
        selection: String?,
        selectionArgs: Array<String>?
    ): String? {
        var cursor: Cursor? = null
        val column = MediaStore.MediaColumns.DATA
        val projection = arrayOf(column)
        try {
            cursor = context.contentResolver.query(uri, projection, selection, selectionArgs, null)
            if (cursor != null && cursor.moveToFirst()) {
                val columnIndex = cursor.getColumnIndexOrThrow(column)
                return cursor.getString(columnIndex)
            }
        } catch (_: Exception) {
        } finally {
            cursor?.close()
        }
        return null
    }

    fun getFileName(context: Context, uri: Uri, fallbackPath: String?): String {
        if (fallbackPath != null) {
            val name = File(fallbackPath).name
            if (name.isNotEmpty()) return name
        }
        var name = "video_${System.currentTimeMillis()}.mp4"
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIdx >= 0) {
                        val n = cursor.getString(nameIdx)
                        if (!n.isNullOrEmpty()) name = n
                    }
                }
            }
        } catch (_: Exception) {}
        return name
    }

    fun copyToCacheIfNeeded(context: Context, uri: Uri, fileName: String): String? {
        return try {
            val cacheFolder = File(context.cacheDir, "picked_media")
            if (!cacheFolder.exists()) cacheFolder.mkdirs()
            val targetFile = File(cacheFolder, fileName)
            context.contentResolver.openInputStream(uri)?.use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            targetFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun isExternalStorageDocument(uri: Uri) =
        "com.android.externalstorage.documents" == uri.authority

    private fun isDownloadsDocument(uri: Uri) =
        "com.android.providers.downloads.documents" == uri.authority

    private fun isMediaDocument(uri: Uri) =
        "com.android.providers.media.documents" == uri.authority

    private fun isGooglePhotosUri(uri: Uri) =
        "com.google.android.apps.photos.content" == uri.authority
}
