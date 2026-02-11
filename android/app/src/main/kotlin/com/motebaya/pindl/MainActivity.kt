package com.motebaya.pindl

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * MainActivity with CORRECT storage handling for Android 10+
 * 
 * CRITICAL FIX: All READ operations use DIRECT FILE ACCESS, not MediaStore queries.
 * 
 * Reason: MediaStore entries have implicit ownership. After app reinstall,
 * the new app instance cannot see MediaStore entries created by the previous
 * installation. However, the actual files still exist on disk and can be
 * accessed directly via java.io.File.
 * 
 * Strategy:
 * - WRITE operations: Use MediaStore API (required on Android 10+)
 * - READ operations: Use direct File access (works regardless of ownership)
 * - DELETE operations: Use direct File.delete() first, then cleanup MediaStore
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "PinDL-MainActivity"
    }

    private val MEDIA_CHANNEL = "com.motebaya.pindl/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // DO NOT call super.configureFlutterEngine() — it triggers
        // GeneratedPluginRegistrant.registerWith() which unconditionally
        // registers FFmpegKitFlutterPlugin. For the lite flavor, the FFmpeg
        // native .so files are stripped, so FFmpegKit's onAttachedToActivity()
        // calls NativeLoader.loadFFmpeg() -> System.loadLibrary("avutil")
        // -> UnsatisfiedLinkError -> fatal Error, killing ALL platform channels.
        //
        // Instead, we manually register each plugin and conditionally include
        // FFmpegKit only for the "ffmpeg" flavor where native libs are present.
        registerPluginsManually(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL).setMethodCallHandler { call, result ->
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

    /**
     * Manual plugin registration — replaces GeneratedPluginRegistrant.
     *
     * Registers all Flutter plugins EXCEPT FFmpegKit for the lite flavor.
     * For the ffmpeg flavor, all plugins including FFmpegKit are registered.
     *
     * Why: GeneratedPluginRegistrant unconditionally registers FFmpegKitFlutterPlugin,
     * but the lite APK has FFmpeg native .so files stripped. When the plugin initializes
     * (onAttachedToActivity -> init -> registerGlobalCallbacks), it triggers
     * FFmpegKitConfig's static initializer which calls System.loadLibrary("avutil"),
     * throwing a fatal UnsatisfiedLinkError that kills the entire plugin system.
     */
    private fun registerPluginsManually(flutterEngine: FlutterEngine) {
        // Core plugins — always registered for both flavors
        try {
            flutterEngine.plugins.add(com.mr.flutter.plugin.filepicker.FilePickerPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering file_picker", e)
        }
        try {
            flutterEngine.plugins.add(io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering flutter_plugin_android_lifecycle", e)
        }
        try {
            flutterEngine.plugins.add(io.flutter.plugins.pathprovider.PathProviderPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering path_provider", e)
        }
        try {
            flutterEngine.plugins.add(com.baseflow.permissionhandler.PermissionHandlerPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering permission_handler", e)
        }
        try {
            flutterEngine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering shared_preferences", e)
        }
        try {
            flutterEngine.plugins.add(io.flutter.plugins.urllauncher.UrlLauncherPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering url_launcher", e)
        }
        try {
            flutterEngine.plugins.add(io.flutter.plugins.videoplayer.VideoPlayerPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering video_player", e)
        }

        // FFmpegKit — only register for the "ffmpeg" flavor where native libs are present
        if (BuildConfig.FLAVOR == "ffmpeg") {
            Log.i(TAG, "FFmpeg flavor: registering FFmpegKitFlutterPlugin")
            try {
                flutterEngine.plugins.add(com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin())
            } catch (e: Exception) {
                Log.e(TAG, "Error registering FFmpegKit", e)
            }
        } else {
            Log.i(TAG, "Lite flavor: skipping FFmpegKit plugin registration (native libs stripped)")
        }
    }

    /**
     * Get the Downloads directory path.
     * Works on all Android versions.
     */
    private fun getDownloadsDirectory(): File {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    }

    /**
     * Check if a file exists in the public Downloads directory.
     * 
     * CRITICAL: Uses DIRECT FILE ACCESS, not MediaStore query.
     * This works after app reinstall because we're checking the actual filesystem,
     * not the MediaStore database which has ownership scoping.
     */
    private fun checkFileExists(filename: String, subFolder: String): Boolean {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        val exists = file.exists() && file.isFile
        
        println("[checkFileExists] Path: ${file.absolutePath}, exists: $exists")
        return exists
    }

    /**
     * List files in a folder within the public Downloads directory.
     * 
     * Uses HYBRID approach:
     * 1. Try DIRECT FILE ACCESS first (works if MANAGE_EXTERNAL_STORAGE granted)
     * 2. Fallback to MediaStore query (works for files created by current app)
     * 
     * IMPORTANT: For "continue" mode to work after reinstall, user MUST grant
     * MANAGE_EXTERNAL_STORAGE permission.
     */
    private fun listFilesInFolder(subFolder: String, extension: String?): List<String> {
        val downloadDir = getDownloadsDirectory()
        val folder = File(downloadDir, subFolder)
        
        println("[listFilesInFolder] Checking folder: ${folder.absolutePath}")
        println("[listFilesInFolder] Folder exists: ${folder.exists()}, isDirectory: ${folder.isDirectory}")
        
        // Check if we have MANAGE_EXTERNAL_STORAGE permission
        val hasFullAccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
        println("[listFilesInFolder] Has MANAGE_EXTERNAL_STORAGE: $hasFullAccess")
        
        if (!folder.exists() || !folder.isDirectory) {
            println("[listFilesInFolder] Folder does not exist or is not a directory")
            // If direct access fails, try MediaStore query as fallback
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return listFilesViaMediaStore(subFolder, extension)
            }
            return emptyList()
        }
        
        val rawFiles = folder.listFiles()
        println("[listFilesInFolder] Raw listFiles() returned: ${rawFiles?.size ?: "null"} items")
        rawFiles?.forEach { f ->
            println("[listFilesInFolder] Raw file: ${f.name}, isFile: ${f.isFile}, canRead: ${f.canRead()}")
        }
        
        val files = rawFiles?.filter { file ->
            if (!file.isFile) return@filter false
            
            // Filter by extension if specified
            if (extension != null) {
                val hasExtension = file.name.endsWith(".$extension", ignoreCase = true) ||
                                   file.name.endsWith(extension, ignoreCase = true)
                if (!hasExtension) return@filter false
            }
            
            // Filter out duplicate files like "(1).json", "(2).jpg"
            val isDuplicate = file.name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))
            if (isDuplicate) {
                println("[listFilesInFolder] Filtering out duplicate: ${file.name}")
                return@filter false
            }
            
            true
        }?.map { it.name }?.sorted() ?: emptyList()
        
        println("[listFilesInFolder] Filtered to ${files.size} files: $files")
        
        // If direct access returns nothing but folder exists, try MediaStore as fallback
        if (files.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            println("[listFilesInFolder] Direct access returned 0 files, trying MediaStore fallback...")
            val mediaStoreFiles = listFilesViaMediaStore(subFolder, extension)
            if (mediaStoreFiles.isNotEmpty()) {
                println("[listFilesInFolder] MediaStore found ${mediaStoreFiles.size} files: $mediaStoreFiles")
                return mediaStoreFiles
            }
        }
        
        return files
    }
    
    /**
     * List files via MediaStore query (fallback for scoped storage).
     * Only returns files owned by current app installation.
     */
    private fun listFilesViaMediaStore(subFolder: String, extension: String?): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return emptyList()
        }
        
        try {
            val resolver = contentResolver
            val projection = arrayOf(MediaStore.Downloads.DISPLAY_NAME)
            
            // Build selection
            var selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
            val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$subFolder%"
            val selectionArgsList = mutableListOf(relativePath)
            
            if (extension != null) {
                selection += " AND ${MediaStore.Downloads.DISPLAY_NAME} LIKE ?"
                selectionArgsList.add("%.$extension")
            }
            
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgsList.toTypedArray(),
                "${MediaStore.Downloads.DISPLAY_NAME} ASC"
            )
            
            val files = mutableListOf<String>()
            cursor?.use {
                val nameColumn = it.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                while (it.moveToNext()) {
                    val name = it.getString(nameColumn)
                    // Filter out duplicates
                    if (!name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))) {
                        files.add(name)
                    } else {
                        println("[listFilesViaMediaStore] Filtering out duplicate: $name")
                    }
                }
            }
            
            println("[listFilesViaMediaStore] Found ${files.size} files via MediaStore")
            return files
        } catch (e: Exception) {
            println("[listFilesViaMediaStore] Error: ${e.message}")
            return emptyList()
        }
    }

    /**
     * Read text content from a file in the public Downloads directory.
     * 
     * CRITICAL: Uses DIRECT FILE ACCESS, not MediaStore query.
     * This works after app reinstall because we're reading the actual file,
     * not querying MediaStore which has ownership scoping.
     */
    private fun readTextFromPublicDirectory(filename: String, subFolder: String): String? {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        
        println("[readTextFromPublicDirectory] Reading: ${file.absolutePath}")
        println("[readTextFromPublicDirectory] File exists: ${file.exists()}")
        
        return if (file.exists() && file.isFile) {
            try {
                val content = file.readText(Charsets.UTF_8)
                println("[readTextFromPublicDirectory] Read ${content.length} chars")
                content
            } catch (e: Exception) {
                println("[readTextFromPublicDirectory] Error reading file: ${e.message}")
                null
            }
        } else {
            println("[readTextFromPublicDirectory] File does not exist")
            null
        }
    }

    /**
     * Delete a file from the public Downloads directory.
     * 
     * CRITICAL: Uses DIRECT FILE DELETE first, then cleans up MediaStore.
     * Direct delete works because we have write access to Downloads folder.
     */
    private fun deleteFileFromPublicDirectory(filename: String, subFolder: String): Boolean {
        val downloadDir = getDownloadsDirectory()
        val file = File(File(downloadDir, subFolder), filename)
        
        println("[deleteFileFromPublicDirectory] Deleting: ${file.absolutePath}")
        
        // Step 1: Try direct file delete (works for files in Downloads)
        if (file.exists()) {
            val deleted = file.delete()
            println("[deleteFileFromPublicDirectory] Direct delete result: $deleted")
            
            if (deleted) {
                // Step 2: Also cleanup MediaStore entry (optional, for consistency)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cleanupMediaStoreEntry(filename, subFolder)
                }
                return true
            }
        }
        
        // Fallback: Try MediaStore delete (for files created in current session)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return deleteViaMediaStore(filename, subFolder)
        }
        
        return false
    }

    /**
     * Cleanup any "(1).json", "(2).json" etc. duplicate files
     */
    private fun cleanupDuplicateFiles(folder: File, canonicalName: String) {
        val baseName = canonicalName.substringBeforeLast(".")
        val extension = canonicalName.substringAfterLast(".")
        
        folder.listFiles()?.forEach { file ->
            if (file.name.startsWith(baseName) && 
                file.name.endsWith(".$extension") &&
                file.name.matches(Regex(".*\\(\\d+\\)\\.\\w+$"))) {
                println("[cleanupDuplicateFiles] Deleting duplicate: ${file.name}")
                file.delete()
            }
        }
    }

    /**
     * Cleanup MediaStore entry (best effort, may fail if not owned by current app)
     */
    private fun cleanupMediaStoreEntry(filename: String, subFolder: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = contentResolver
                val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
                val selectionArgs = arrayOf(filename, "%$subFolder%")
                val deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
                println("[cleanupMediaStoreEntry] MediaStore cleanup: $deleted entries")
            } catch (e: Exception) {
                println("[cleanupMediaStoreEntry] MediaStore cleanup failed (expected after reinstall): ${e.message}")
            }
        }
    }

    /**
     * Delete via MediaStore (fallback for files created in current session)
     */
    private fun deleteViaMediaStore(filename: String, subFolder: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = contentResolver
                
                // Try with trailing slash
                var selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?"
                var selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/")
                var deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
                
                // Try without trailing slash
                if (deleted == 0) {
                    selectionArgs = arrayOf(filename, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                    deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
                }
                
                return deleted > 0
            } catch (e: Exception) {
                println("[deleteViaMediaStore] Error: ${e.message}")
            }
        }
        return false
    }

    /**
     * Save a file to the public Downloads directory.
     * 
     * Uses MediaStore on Android 10+ (required), but FIRST deletes any existing
     * file via direct file access to prevent "(1)" duplicates.
     */
    private fun saveToPublicDirectory(
        sourcePath: String, 
        filename: String, 
        mimeType: String, 
        subFolder: String, 
        overwrite: Boolean
    ): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw Exception("Source file does not exist: $sourcePath")
        }

        val downloadDir = getDownloadsDirectory()
        val targetDir = File(downloadDir, subFolder)
        val targetFile = File(targetDir, filename)

        // CRITICAL: If overwrite, delete existing file via DIRECT ACCESS first
        if (overwrite && targetFile.exists()) {
            println("[saveToPublicDirectory] Overwrite: deleting existing file via direct access")
            targetFile.delete()
            
            // Also cleanup MediaStore entry
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cleanupMediaStoreEntry(filename, subFolder)
            }
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ - Use MediaStore for writing
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

            println("[saveToPublicDirectory] Saved via MediaStore: $filename")
            "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            // Android 9 and below - Direct file access
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            sourceFile.copyTo(targetFile, overwrite = true)
            sourceFile.delete()
            
            // Scan the file
            scanFile(targetFile.absolutePath)
            
            println("[saveToPublicDirectory] Saved via direct access: ${targetFile.absolutePath}")
            targetFile.absolutePath
        }
    }

    /**
     * Save text content to a file in the public Downloads directory.
     * 
     * ALWAYS overwrites existing file (metadata must be deterministic).
     * 
     * Strategy for preventing duplicates:
     * 1. Query MediaStore for existing file URI
     * 2. If found and we own it: UPDATE the content
     * 3. If found but we don't own it: Delete via direct access, INSERT new
     * 4. If not found: INSERT new
     */
    private fun saveTextToPublicDirectory(content: String, filename: String, subFolder: String): String {
        val downloadDir = getDownloadsDirectory()
        val targetDir = File(downloadDir, subFolder)
        val targetFile = File(targetDir, filename)
        
        println("[saveTextToPublicDirectory] Saving: $filename to $subFolder")
        println("[saveTextToPublicDirectory] Target path: ${targetFile.absolutePath}")

        // Step 1: Cleanup any duplicate files like "(1).json" first
        if (targetDir.exists()) {
            cleanupDuplicateFiles(targetDir, filename)
        }

        // Step 2: Try to find existing MediaStore entry
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val existingUri = findMediaStoreEntry(filename, subFolder)
            
            if (existingUri != null) {
                println("[saveTextToPublicDirectory] Found existing MediaStore entry: $existingUri")
                
                // Try to UPDATE existing entry (only works if we own it)
                try {
                    contentResolver.openOutputStream(existingUri, "wt")?.use { outputStream ->
                        outputStream.write(content.toByteArray(Charsets.UTF_8))
                    }
                    println("[saveTextToPublicDirectory] Successfully UPDATED existing file via MediaStore")
                    return "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
                } catch (e: SecurityException) {
                    println("[saveTextToPublicDirectory] Cannot update (not owned): ${e.message}")
                    // Fall through to delete and re-create
                } catch (e: Exception) {
                    println("[saveTextToPublicDirectory] Update failed: ${e.message}")
                    // Fall through to delete and re-create
                }
            }
            
            // Step 3: Delete existing file via DIRECT ACCESS (works for any file in Downloads)
            if (targetFile.exists()) {
                println("[saveTextToPublicDirectory] Deleting existing file via direct access: ${targetFile.absolutePath}")
                val deleted = targetFile.delete()
                println("[saveTextToPublicDirectory] Direct delete result: $deleted")
            }
            
            // Step 4: Try to clean up orphaned MediaStore entries
            cleanupMediaStoreEntry(filename, subFolder)
            
            // Step 5: Also cleanup any matching entries with LIKE query (catch orphans)
            cleanupOrphanedMediaStoreEntries(filename, subFolder)
            
            // Step 6: INSERT new entry via MediaStore
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

            println("[saveTextToPublicDirectory] Saved via MediaStore INSERT: $filename")
            return "${Environment.DIRECTORY_DOWNLOADS}/$subFolder/$filename"
        } else {
            // Android 9 and below - Direct file access
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            targetFile.writeText(content, Charsets.UTF_8)
            
            println("[saveTextToPublicDirectory] Saved via direct access: ${targetFile.absolutePath}")
            return targetFile.absolutePath
        }
    }
    
    /**
     * Find MediaStore entry by filename and subfolder.
     * Returns the URI if found, null otherwise.
     */
    private fun findMediaStoreEntry(filename: String, subFolder: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        
        try {
            val resolver = contentResolver
            val projection = arrayOf(MediaStore.Downloads._ID)
            
            // Try exact match first
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
                    return Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toString())
                }
            }
        } catch (e: Exception) {
            println("[findMediaStoreEntry] Error: ${e.message}")
        }
        
        return null
    }
    
    /**
     * Cleanup orphaned MediaStore entries that might cause duplicates.
     * Uses LIKE query to catch variations.
     */
    private fun cleanupOrphanedMediaStoreEntries(filename: String, subFolder: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        
        try {
            val resolver = contentResolver
            val baseName = filename.substringBeforeLast(".")
            val extension = filename.substringAfterLast(".")
            
            // Delete any entries that look like duplicates: "filename (1).json", "filename (2).json" etc.
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} LIKE ? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
            val selectionArgs = arrayOf("$baseName%.$extension", "%$subFolder%")
            
            val deleted = resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, selectionArgs)
            println("[cleanupOrphanedMediaStoreEntries] Cleaned up $deleted orphaned entries for pattern: $baseName*.$extension")
        } catch (e: Exception) {
            println("[cleanupOrphanedMediaStoreEntries] Error (expected after reinstall): ${e.message}")
        }
    }

    /**
     * Trigger MediaScanner to make file visible in gallery/file explorer
     */
    private fun scanFile(path: String) {
        val file = File(path)
        if (file.exists()) {
            MediaScannerConnection.scanFile(
                this,
                arrayOf(path),
                null
            ) { scannedPath, uri ->
                println("[scanFile] MediaScanner completed for: $scannedPath -> $uri")
            }
        }
    }
}
