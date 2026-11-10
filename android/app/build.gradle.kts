import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing properties from a local file that is NOT in git.
// Copy android/key.properties.example to android/key.properties and fill in
// your keystore details. Never commit the real key.properties.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

android {
    namespace = "com.github.ytdlp"
    // Flutter's default is 36, but receive_sharing_intent 1.9.0 compiles
    // against 37. compileSdk only gates which APIs are visible at compile
    // time; it does not change the runtime behaviour, which targetSdk drives.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (Java 8+ APIs on older devices).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.github.ytdlp"
        minSdk = flutter.minSdkVersion
        // targetSdk 33 is now supported via the run-as wrapper:
        // Android 10+ (API 29+) enforces W^X for apps that target API 29+, so
        // exec() on files in app-writable storage is denied
        // (untrusted_app -> avc: denied { execute_no_trans }).
        // The app now uses `run-as com.github.ytdlp sh -c '...'` to execute the
        // bundled CPython runtime, which runs in the app's UID but with the
        // shell's SELinux context (untrusted_app -> shell), bypassing W^X.
        // This allows targeting API 33+ while keeping the bundled runtime working.
        // To override: flutter build apk --release -P ytdlpTargetSdk=28
        targetSdk =
            (project.findProperty("ytdlpTargetSdk") as String?)?.toInt() ?: 33
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APVersions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            storePassword = keyProperties.getProperty("storePassword")
            val storePath = keyProperties.getProperty("storeFile")
            if (!storePath.isNullOrBlank()) {
                storeFile = rootProject.file(storePath)
            }
        }
    }

    buildTypes {
        release {
            // Fail with an actionable message instead of a signing error deep in
            // the build when the keystore has not been set up yet.
            if (keyPropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "YTDL: android/key.properties not found — falling back to the " +
                        "debug key for this release build. Copy " +
                        "android/key.properties.example to android/key.properties " +
                        "and fill it in to produce a redistributable APK."
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    lint {
        // Play-only policy check: Google Play requires a recent targetSdk, but
        // this app is distributed via sideload/F-Droid/GitHub (YouTube
        // downloading is barred from Play). The run-as wrapper allows
        // targetSdk 33+ while keeping the bundled runtime executable.
        // Every other lint rule stays active, for release builds included.
        disable += "ExpiredTargetSdkVersion"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring for flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
