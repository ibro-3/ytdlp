plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ytdlp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (Java 8+ APIs on older devices).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.ytdlp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // targetSdk 28 keeps the bundled Termux CPython runtime executable:
        // Android 10+ (API 29+) enforces W^X for apps that target API 29+, so
        // exec() on files in app-writable storage is denied
        // (untrusted_app -> avc: denied { execute_no_trans }), which silently
        // breaks running the runtime we extract into the app support dir.
        // Termux ships targetSdk 28 for the same reason.
        // Trade-off: sideload/F-Droid only; see README "Android notes".
        // To experiment with a higher target:
        //   flutter build apk --release -P ytdlpTargetSdk=33
        // (see the lint disable below and README before doing so — the bundled
        // runtime stops being executable at API 29+.)
        targetSdk =
            (project.findProperty("ytdlpTargetSdk") as String?)?.toInt() ?: 28
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            // Release APKs are therefore NOT redistributable as-is — create a
            // real keystore before publishing anywhere.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    lint {
        // Play-only policy check: Google Play requires a recent targetSdk, but
        // this app is distributed via sideload/F-Droid/GitHub (YouTube
        // downloading is barred from Play) and targetSdk 28 is required for the
        // bundled runtime. Every other lint rule stays active, for release
        // builds included.
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
