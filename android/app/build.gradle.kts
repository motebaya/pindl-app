import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load key.properties if it exists
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.motebaya.pindl"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
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
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
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
            signingConfig = if (keystorePropertiesFile.exists()) {
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
