package com.motebaya.pindl

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val MEDIA_CHANNEL = "com.motebaya.pindl/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val filename = call.argument<String>("filename")
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val subFolder = call.argument<String>("subFolder") ?: "PinDL"
                    
                    if (sourcePath != null && filename != null) {
                        try {
                            val savedPath = saveToPublicDirectory(sourcePath, filename, mimeType, subFolder)
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
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
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
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        // On Android 10+, we use MediaStore and files go to Downloads
                        result.success("Downloads/$subFolder")
                    } else {
                        val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        val pindlDir = File(downloadDir, subFolder)
                        if (!pindlDir.exists()) {
                            pindlDir.mkdirs()
                        }
                        result.success(pindlDir.absolutePath)
                    }
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
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToPublicDirectory(sourcePath: String, filename: String, mimeType: String, subFolder: String): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw Exception("Source file does not exist: $sourcePath")
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Use MediaStore
            val resolver = contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("Failed to create MediaStore entry")

            resolver.openOutputStream(uri)?.use { outputStream ->
                FileInputStream(sourceFile).use { inputStream ->
                    inputStream.copyTo(outputStream)
                }
            } ?: throw Exception("Failed to open output stream")

            // Mark as complete
            contentValues.clear()
            contentValues.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)

            // Delete the temp file
            sourceFile.delete()

            "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            // Android 9 and below - Direct file access
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val pindlDir = File(downloadDir, subFolder)
            if (!pindlDir.exists()) {
                pindlDir.mkdirs()
            }
            val destFile = File(pindlDir, filename)
            sourceFile.copyTo(destFile, overwrite = true)
            sourceFile.delete()
            
            // Scan the file
            scanFile(destFile.absolutePath)
            
            destFile.absolutePath
        }
    }

    private fun saveTextToPublicDirectory(content: String, filename: String, subFolder: String): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Use MediaStore for Documents
            // First, delete existing file if it exists (to prevent "(1).json" duplication)
            deleteFileFromPublicDirectory(filename, subFolder)
            
            val resolver = contentResolver
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

            // Mark as complete
            contentValues.clear()
            contentValues.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)

            "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            // Android 9 and below - Direct file access (overwrite by default)
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val pindlDir = File(downloadDir, subFolder)
            if (!pindlDir.exists()) {
                pindlDir.mkdirs()
            }
            val destFile = File(pindlDir, filename)
            destFile.writeText(content, Charsets.UTF_8)
            
            destFile.absolutePath
        }
    }
    
    private fun deleteFileFromPublicDirectory(filename: String, subFolder: String): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Query and delete from MediaStore
            val resolver = contentResolver
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
            
            val deletedCount = resolver.delete(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                selection,
                selectionArgs
            )
            deletedCount > 0
        } else {
            // Android 9 and below - Direct file delete
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val file = File(File(downloadDir, subFolder), filename)
            if (file.exists()) {
                file.delete()
            } else {
                false
            }
        }
    }

    private fun readTextFromPublicDirectory(filename: String, subFolder: String): String? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Query MediaStore
            val resolver = contentResolver
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
            
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )
            
            cursor?.use {
                if (it.moveToFirst()) {
                    val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                    val uri = Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toString())
                    
                    resolver.openInputStream(uri)?.use { inputStream ->
                        return inputStream.bufferedReader().readText()
                    }
                }
            }
            null
        } else {
            // Android 9 and below - Direct file access
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val file = File(File(downloadDir, subFolder), filename)
            if (file.exists()) {
                file.readText(Charsets.UTF_8)
            } else {
                null
            }
        }
    }

    private fun scanFile(path: String) {
        val file = File(path)
        if (file.exists()) {
            MediaScannerConnection.scanFile(
                this,
                arrayOf(path),
                null
            ) { scannedPath, uri ->
                println("MediaScanner completed for: $scannedPath -> $uri")
            }
        }
    }
    
    private fun checkFileExists(filename: String, subFolder: String): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Query MediaStore
            val resolver = contentResolver
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
            
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )
            
            val exists = cursor?.use { it.count > 0 } ?: false
            exists
        } else {
            // Android 9 and below - Direct file access
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val file = File(File(downloadDir, subFolder), filename)
            file.exists()
        }
    }

    private fun listFilesInFolder(subFolder: String, extension: String?): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Query MediaStore
            val resolver = contentResolver
            val projection = arrayOf(MediaStore.Downloads.DISPLAY_NAME)
            val selection = "${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val selectionArgs = arrayOf("${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
            
            val files = mutableListOf<String>()
            
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )
            
            cursor?.use {
                val nameColumn = it.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                while (it.moveToNext()) {
                    val name = it.getString(nameColumn)
                    if (extension == null || name.endsWith(extension)) {
                        files.add(name)
                    }
                }
            }
            files
        } else {
            // Android 9 and below - Direct file access
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val folder = File(downloadDir, subFolder)
            if (folder.exists() && folder.isDirectory) {
                folder.listFiles()?.filter { file ->
                    file.isFile && (extension == null || file.name.endsWith(extension))
                }?.map { it.name } ?: emptyList()
            } else {
                emptyList()
            }
        }
    }
}
