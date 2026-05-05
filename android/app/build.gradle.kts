plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.sharer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Slice 5.2.1: flutter_local_notifications uses java.time APIs
        // that aren't in the platform's core library on older Android
        // versions, so D8 needs to desugar them in. Without this the
        // AAR-metadata check fails with:
        //   "Dependency ':flutter_local_notifications' requires core
        //    library desugaring to be enabled for :app."
        // See https://developer.android.com/studio/write/java8-support
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.sharer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Slice 5.2.1: pairs with `isCoreLibraryDesugaringEnabled` above.
    // Required for flutter_local_notifications' use of java.time on
    // older Android versions. Bump together with AGP / Flutter SDK if
    // a newer release demands it.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
