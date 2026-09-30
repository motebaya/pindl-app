package com.motebaya.pindl

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

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

        // Phase 11.1: debug-only boot assert (AND-1 silent-kill detector) —
        // resolve every expected plugin class without initializing it and log
        // a LOUD error naming any class an upgrade renamed/moved. No-op in
        // release builds.
        if (BuildConfig.DEBUG) {
            BootPluginAssert.assertRegisteredPlugins(BuildConfig.FLAVOR)
        }

        // Register the media MethodChannel via extracted handler (reusable in background engine)
        MediaChannelHandler(this).register(flutterEngine)
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
        // (Phase 12.3/OQ-5: file_picker removed — no Dart call sites ever
        // existed; the SAF comment in pubspec predates the storage design.)
        // Phase 12.3: flutter_plugin_android_lifecycle was file_picker's
        // TRANSITIVE dep — removed from the graph together with it (drift
        // test caught the stale entry on its first real run).
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

        // flutter_foreground_task — always registered for both flavors
        try {
            flutterEngine.plugins.add(com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering flutter_foreground_task", e)
        }

        // flutter_local_notifications — for progress bar + completion heads-up
        try {
            flutterEngine.plugins.add(com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering flutter_local_notifications", e)
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
}
