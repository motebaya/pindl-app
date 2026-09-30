package com.motebaya.pindl

import android.util.Log

/**
 * Phase 11.1 — DEBUG boot assert for the manual plugin registration (AND-1).
 *
 * Manual registration means a dependency upgrade that renames/moves a plugin
 * class compiles cleanly but kills that plugin at runtime (per-plugin
 * try/catch → missing capability, not crash). After
 * [MainActivity.registerPluginsManually], this assert resolves every expected
 * FQCN and logs a LOUD error naming any class that no longer exists.
 *
 * CRITICAL: `Class.forName(name)` would run the class's static initializer —
 * for FFmpegKit that is exactly the `System.loadLibrary("avutil")` path that
 * hard-kills the lite flavor (the UnsatisfiedLinkError manual registration
 * exists to prevent). We therefore pass `initialize = false` AND skip the
 * FFmpegKit entry on non-ffmpeg flavors. Resolution-only + load-free + init-
 * free is safe: nothing is linked, nothing is registered twice.
 *
 * The class list MUST stay in sync with MainActivity.registerPluginsManually
 * (the Dart-side drift test test/platform/plugin_registration_drift_test.dart
 * pins the same list against `.flutter-plugins-dependencies`).
 */
object BootPluginAssert {
    private const val TAG = "PinDL-PluginAssert"

    /// name → (FQCN, allFlavors). The ffmpeg entry is allFlavors=false:
    /// asserted ONLY when [flavor] == "ffmpeg".
    /// Phase 12.3/OQ-5: file_picker removed (dependency deleted — no Dart
    /// call sites ever existed).
    private val expected: Map<String, Pair<String, Boolean>> = mapOf(
        "path_provider_android" to
            Pair("io.flutter.plugins.pathprovider.PathProviderPlugin", true),
        "permission_handler_android" to
            Pair("com.baseflow.permissionhandler.PermissionHandlerPlugin", true),
        "shared_preferences_android" to
            Pair("io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin", true),
        "url_launcher_android" to
            Pair("io.flutter.plugins.urllauncher.UrlLauncherPlugin", true),
        "video_player_android" to
            Pair("io.flutter.plugins.videoplayer.VideoPlayerPlugin", true),
        "flutter_foreground_task" to
            Pair("com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin", true),
        "flutter_local_notifications" to
            Pair("com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin", true),
        // (name, FQCN, allFlavors=false → ffmpeg flavor only)
        "ffmpeg_kit_flutter_new_https" to
            Pair("com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin", false),
    )

    /**
     * Resolve every expected plugin class (no init, no static side effects)
     * and log dead ones. Runs ONLY in debug builds (caller-gated).
     */
    fun assertRegisteredPlugins(flavor: String) {
        val dead = mutableListOf<String>()
        var checked = 0
        for ((name, spec) in expected) {
            val (fqcn, allFlavors) = spec
            if (!allFlavors && flavor != "ffmpeg") continue
            try {
                // initialize=false: resolve the class WITHOUT running its
                // static initializer (FFmpegKit's would load native libs).
                Class.forName(fqcn, false, BootPluginAssert::class.java.classLoader)
                checked++
            } catch (t: Throwable) {
                dead.add("$name (${t.javaClass.simpleName}: $fqcn)")
            }
        }
        if (dead.isNotEmpty()) {
            Log.e(TAG, "PLUGIN REGISTRATION DRIFT — ${dead.size} plugin class(es) no longer resolve; " +
                "upgrade renamed/moved them and they will NOT work at runtime: $dead. " +
                "Update MainActivity.registerPluginsManually + BootPluginAssert + " +
                "test/platform/plugin_registration_drift_test.dart (kManualAndroidPlugins).")
        } else {
            Log.i(TAG, "All $checked expected plugin classes resolve for flavor=$flavor " +
                "(initialize=false, no side effects).")
        }
    }
}
