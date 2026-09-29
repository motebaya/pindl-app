import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing properties with fallback lookup order (Phase 01 containment):
//   1. project key.properties (legacy, git-ignored; may contain placeholder values)
//   2. user-level ~/.gradle/pindl-signing.properties (canonical location - outside any repo)
//   3. no signing properties -> release builds fall back to debug signing (existing behavior)
// A properties file counts as usable only if it carries a real (non-placeholder) password.
val keystorePropertiesFile = rootProject.file("key.properties")
val userKeystorePropertiesFile = File(System.getProperty("user.home"), ".gradle/pindl-signing.properties")

fun loadSigningProperties(candidate: java.io.File): Properties? {
    if (!candidate.exists()) return null
    val props = Properties()
    candidate.inputStream().use { props.load(it) }
    val sp = props.getProperty("storePassword") ?: ""
    if (sp.isBlank() || sp.startsWith("<")) return null // placeholder/template -> not usable
    return props
}

val resolvedKeystoreProperties = loadSigningProperties(keystorePropertiesFile)
    ?: loadSigningProperties(userKeystorePropertiesFile)
val keystoreProperties = resolvedKeystoreProperties ?: Properties() // empty dummy when no real config; signing falls back to debug
val keystorePropertiesFileExists = resolvedKeystoreProperties != null

android {
    namespace = "com.motebaya.pindl"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications for java.time API support
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // Required for AGP 8.x — BuildConfig generation is disabled by default.
    // We use BuildConfig.FLAVOR in MainActivity to conditionally register FFmpegKit.
    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.motebaya.pindl"
        minSdk = 24  // Required for FFmpegKit (HLS conversion support)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "mode"
    productFlavors {
        create("lite") {
            dimension = "mode"
            applicationIdSuffix = ".lite"
            versionNameSuffix = "-lite"
        }
        create("ffmpeg") {
            dimension = "mode"
            applicationIdSuffix = ".ffmpeg"
            versionNameSuffix = "-ffmpeg"
        }
    }

    signingConfigs {
        if (keystorePropertiesFileExists) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // Resolve storeFile robustly: try as-given (project dir), then relative to android/app,
                // then relative to android/ — covers absolute paths and ../-style entries from either properties file.
                val rawStorePath = keystoreProperties["storeFile"] as String
                val candidates = listOfNotNull(
                    rootProject.file(rawStorePath),                                    // <repo>/android
                    file(rawStorePath),                                                // <repo>/android/app
                    rootProject.projectDir.parentFile?.let { File(it, rawStorePath) }  // repo root
                )
                val storeFileResolved = candidates.firstOrNull { it.exists() }
                    ?: candidates.first() // keep original error message if truly missing
                storeFile = storeFileResolved
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (keystorePropertiesFileExists) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required for flutter_local_notifications core library desugaring
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Exclude FFmpeg native libraries from the lite flavor to reduce APK size.
// The Dart code is already guarded by BuildConfig.enableFfmpeg (defaults to false),
// so HlsConverter is never instantiated in lite builds — no runtime crash.
androidComponents {
    onVariants(selector().withFlavor("mode" to "lite")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(listOf(
            // Standard names (arm64-v8a, x86_64)
            "**/libavcodec.so",
            "**/libavdevice.so",
            "**/libavfilter.so",
            "**/libavformat.so",
            "**/libavutil.so",
            "**/libffmpegkit.so",
            "**/libffmpegkit_abidetect.so",
            "**/libswresample.so",
            "**/libswscale.so",
            // NEON-suffixed names (armeabi-v7a)
            "**/libavcodec_neon.so",
            "**/libavdevice_neon.so",
            "**/libavfilter_neon.so",
            "**/libavformat_neon.so",
            "**/libavutil_neon.so",
            "**/libffmpegkit_armv7a_neon.so",
            "**/libswresample_neon.so",
            "**/libswscale_neon.so",
        ))
    }
}
