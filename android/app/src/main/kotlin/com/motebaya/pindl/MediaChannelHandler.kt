package com.motebaya.pindl

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Extracted MethodChannel handler for PinDL media operations.
 *
 * Reusable across MainActivity and background FlutterEngine instances
 * (e.g., when WorkManager restarts after Android 15 timeout).
 *
 * Handles:
 * - saveFileToDownloads, saveTextToFile, readTextFromFile
 * - scanFile, fileExists, listFilesInFolder, deleteFile
 * - requestManageStorage, hasManageStoragePermission, getPublicDownloadPath
 */
class MediaChannelHandler(private val context: Context) {
    companion object {
        private const val TAG = "PinDL-MediaChannel"
        const val CHANNEL_NAME = "com.motebaya.pindl/media"
    }

    /**
     * Register the MethodChannel on the given FlutterEngine.
     * Can be called from both MainActivity and background engine setups.
     */
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val filename = call.argument<String>("filename")
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"
                    val overwrite = call.argument<Boolean>("overwrite") ?: true

                    if (sourcePath != null && filename != null) {
                        try {
                            val savedPath = saveToPublicDirectory(sourcePath, filename, mimeType, subFolder, overwrite)
                            result.success(savedPath)
                        } catch (e: Exception) {
                            result.error("SAVE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "sourcePath and filename are required", null)
                    }
                }
                "saveTextToFile" -> {
                    val content = call.argument<String>("content")
                    val filename = call.argument<String>("filename")
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL/metadata"

                    if (content != null && filename != null) {
                        try {
                            val savedPath = saveTextToPublicDirectory(content, filename, subFolder)
                            result.success(savedPath)
                        } catch (e: Exception) {
                            result.error("SAVE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "content and filename are required", null)
                    }
                }
                "readTextFromFile" -> {
                    val filename = call.argument<String>("filename")
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"

                    if (filename != null) {
                        try {
                            val content = readTextFromPublicDirectory(filename, subFolder)
                            result.success(content)
                        } catch (e: Exception) {
                            result.error("READ_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "filename is required", null)
                    }
                }
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        scanFile(path)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "Path is required", null)
                    }
                }
                "requestManageStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        if (!Environment.isExternalStorageManager()) {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            intent.data = Uri.parse("package:${context.packageName}")
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(false)
                        } else {
                            result.success(true)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "hasManageStoragePermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                "getPublicDownloadPath" -> {
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"
                    val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    val pindlDir = File(downloadDir, subFolder)
                    result.success(pindlDir.absolutePath)
                }
                "fileExists" -> {
                    val filename = call.argument<String>("filename")
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"

                    if (filename != null) {
                        val exists = checkFileExists(filename, subFolder)
                        result.success(exists)
                    } else {
                        result.error("INVALID_ARGUMENT", "filename is required", null)
                    }
                }
                "listFilesInFolder" -> {
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"
                    val extension = call.argument<String>("extension")

                    try {
                        val files = listFilesInFolder(subFolder, extension)
                        result.success(files)
                    } catch (e: Exception) {
                        result.error("LIST_ERROR", e.message, null)
                    }
                }
                "deleteFile" -> {
                    val filename = call.argument<String>("filename")
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"

                    if (filename != null) {
                        val deleted = deleteFileFromPublicDirectory(filename, subFolder)
                        result.success(deleted)
                    } else {
                        result.error("INVALID_ARGUMENT", "filename is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── File operations (same logic as original MainActivity) ──

    private fun getDownloadsDirectory(): File {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    }

    private fun checkFileExists(filename: String, subFolder: String): Boolean {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        return file.exists() && file.isFile
    }

    private fun listFilesInFolder(subFolder: String, extension: String?): List<String> {
        val downloadDir = getDownloadsDirectory()
        val folder = File(downloadDir, subFolder)

        if (!folder.exists() || !folder.isDirectory) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return listFilesViaMediaStore(subFolder, extension)
            }
            return emptyList()
        }

        val rawFiles = folder.listFiles()
        val files = rawFiles?.filter { file ->
            if (!file.isFile) return@filter false
            if (extension != null) {
                val hasExtension = file.name.endsWith(".$extension", ignoreCase = true) ||
                                   file.name.endsWith(extension, ignoreCase = true)
                if (!hasExtension) return@filter false
            }
            val isDuplicate = file.name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))
            !isDuplicate
        }?.map { it.name }?.sorted() ?: emptyList()

        if (files.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val mediaStoreFiles = listFilesViaMediaStore(subFolder, extension)
            if (mediaStoreFiles.isNotEmpty()) return mediaStoreFiles
        }

        return files
    }

    private fun listFilesViaMediaStore(subFolder: String, extension: String?): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
        try {
            val resolver = context.contentResolver
            val projection = arrayOf(MediaStore.Downloads.DISPLAY_NAME)
            var selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
            val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$subFolder%"
            val selectionArgsList = mutableListOf(relativePath)
            if (extension != null) {
                selection += " AND ${MediaStore.Downloads.DISPLAY_NAME} LIKE ?"
                selectionArgsList.add("%.$extension")
            }
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, projection,
                selection, selectionArgsList.toTypedArray(),
                "${MediaStore.Downloads.DISPLAY_NAME} ASC"
            )
            val files = mutableListOf<String>()
            cursor?.use {
                val nameColumn = it.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                while (it.moveToNext()) {
                    val name = it.getString(nameColumn)
                    if (!name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))) files.add(name)
                }
            }
            return files
        } catch (e: Exception) {
            return emptyList()
        }
    }

    private fun readTextFromPublicDirectory(filename: String, subFolder: String): String? {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        return if (file.exists() && file.isFile) {
            try { file.readText(Charsets.UTF_8) } catch (e: Exception) { null }
        } else null
    }

    private fun deleteFileFromPublicDirectory(filename: String, subFolder: String): Boolean {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        if (file.exists()) {
            val deleted = file.delete()
            if (deleted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cleanupMediaStoreEntry(filename, subFolder)
            }
            if (deleted) return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return deleteViaMediaStore(filename, subFolder)
        }
        return false
    }

    private fun cleanupMediaStoreEntry(filename: String, subFolder: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = context.contentResolver
                val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
                val selectionArgs = arrayOf(filename, "%$subFolder%")
                resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
            } catch (_: Exception) {}
        }
    }

    private fun deleteViaMediaStore(filename: String, subFolder: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = context.contentResolver
                val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
                var selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
                var deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
                if (deleted == 0) {
                    selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                    deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
                }
                return deleted > 0
            } catch (_: Exception) {}
        }
        return false
    }

    private fun cleanupDuplicateFiles(folder: File, canonicalName: String) {
        val baseName = canonicalName.substringBeforeLast(".")
        val extension = canonicalName.substringAfterLast(".")
        folder.listFiles()?.forEach { file ->
            if (file.name.startsWith(baseName) &&
                file.name.endsWith(".$extension") &&
                file.name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))) {
                file.delete()
            }
        }
    }

    private fun cleanupOrphanedMediaStoreEntries(filename: String, subFolder: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val resolver = context.contentResolver
            val baseName = filename.substringBeforeLast(".")
            val extension = filename.substringAfterLast(".")
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} LIKE ? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
            val selectionArgs = arrayOf("$baseName%.$extension", "%$subFolder%")
            resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
        } catch (_: Exception) {}
    }

    private fun findMediaStoreEntry(filename: String, subFolder: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        try {
            val resolver = context.contentResolver
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, projection,
                selection, selectionArgs, null
            )
            cursor?.use {
                if (it.moveToFirst()) {
                    val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                    return Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toString())
                }
            }
        } catch (_: Exception) {}
        return null
    }

    private fun saveToPublicDirectory(
        sourcePath: String, filename: String, mimeType: String,
        subFolder: String, overwrite: Boolean
    ): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) throw Exception("Source file does not exist: $sourcePath")

        val downloadDir = getDownloadsDirectory()
        val targetDir = File(downloadDir, subFolder)
        val targetFile = File(targetDir, filename)

        if (overwrite && targetFile.exists()) {
            targetFile.delete()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) cleanupMediaStoreEntry(filename, subFolder)
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("Failed to create MediaStore entry")
            resolver.openOutputStream(uri)?.use { outputStream ->
                FileInputStream(sourceFile).use { inputStream -> inputStream.copyTo(outputStream) }
            } ?: throw Exception("Failed to open output stream")
            contentValues.clear()
            contentValues.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)
            sourceFile.delete()
            "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            if (!targetDir.exists()) targetDir.mkdirs()
            sourceFile.copyTo(targetFile, overwrite = true)
            sourceFile.delete()
            scanFile(targetFile.absolutePath)
            targetFile.absolutePath
        }
    }

    private fun saveTextToPublicDirectory(content: String, filename: String, subFolder: String): String {
        val downloadDir = getDownloadsDirectory()
        val targetDir = File(downloadDir, subFolder)
        val targetFile = File(targetDir, filename)

        if (targetDir.exists()) cleanupDuplicateFiles(targetDir, filename)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val existingUri = findMediaStoreEntry(filename, subFolder)
            if (existingUri != null) {
                try {
                    context.contentResolver.openOutputStream(existingUri, "wt")?.use { outputStream ->
                        outputStream.write(content.toByteArray(Charsets.UTF_8))
                    }
                    return "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
                } catch (_: SecurityException) {
                } catch (_: Exception) {}
            }
            if (targetFile.exists()) targetFile.delete()
            cleanupMediaStoreEntry(filename, subFolder)
            cleanupOrphanedMediaStoreEntries(filename, subFolder)

            val resolver = context.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("Failed to create MediaStore entry for text file")
            resolver.openOutputStream(uri)?.use { outputStream ->
                outputStream.write(content.toByteArray(Charsets.UTF_8))
            } ?: throw Exception("Failed to open output stream for text file")
            contentValues.clear()
            contentValues.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)
            return "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            if (!targetDir.exists()) targetDir.mkdirs()
            targetFile.writeText(content, Charsets.UTF_8)
            return targetFile.absolutePath
        }
    }

    private fun scanFile(path: String) {
        val file = File(path)
        if (file.exists()) {
            MediaScannerConnection.scanFile(context, arrayOf(path), null, null)
        }
    }
}
