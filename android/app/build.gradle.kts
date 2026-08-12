import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by a gitignored `android/key.properties` that points at the
// org upload keystore (see docs/setup.md). When it's absent — fresh clones, OSS
// contributors, CI without secrets — the release build falls back to the debug key so
// `flutter build` still works; only Play Store uploads need the real key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.appsoflife.swipewise"
    // Pinned ahead of `flutter.compileSdkVersion` (36) because
    // permission_handler_android 14 compiles against 37 and Gradle refuses to
    // build a plugin against a higher SDK than the app.
    //
    // The minor is not decoration. From API 36 on, platforms ship as minor
    // versions — the SDK has `android-37.0` and `android-37.1`, and no plain
    // `android-37` exists at all — so `compileSdk = 37` alone resolves to
    // nothing. AGP had to move to 8.13 to understand this split.
    compileSdk = 37
    compileSdkMinor = 0
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (payment-due reminders): it uses
        // java.time on the Android side, so the build fails with an AAR-metadata error
        // without desugaring. See the coreLibraryDesugaring dependency below — both
        // halves are needed; enabling the flag alone leaves the dependency unresolved.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.appsoflife.swipewise"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // There is deliberately NO free/pro product flavor.
    //
    // Pro is sold as an in-app subscription, which means one app on Play whose
    // features unlock at runtime — nobody subscribes in app A and installs app
    // B. So both tiers ship in one binary and the tier is decided while the app
    // runs (`proEntitlementProvider`), not while it compiles. An earlier
    // revision used flavors to keep Pro code out of the free APK entirely;
    // that is incompatible with subscriptions, and bought little anyway now
    // that the whole app is open source.
    //
    // What still must never ship is the *credentials*, and those come from
    // `--dart-define-from-file`, not from Gradle. `tool/verify_release_apk.py`
    // is the gate that proves it.
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // Distinct applicationId so a locally-installed dev build coexists
            // on-device with the Play (internal-testing) build, which keeps the
            // un-suffixed `com.appsoflife.swipewise`. `flutter run` and the
            // VS Code "debug" launch config install `com.appsoflife.swipewise.dev`
            // with its own sandbox + SQLite db, side by side with the tester build.
            applicationIdSuffix = ".dev"
            // Different launcher label so dev and prod are distinguishable on-device.
            resValue("string", "app_name", "SwipeWiseDev")
        }
        release {
            // Real upload key when key.properties is present; debug key otherwise so
            // contributor builds still work. See docs/setup.md (Release signing).
            signingConfig = signingConfigs.getByName(if (hasReleaseKeystore) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    // Backports java.time etc. to the minSdk. Paired with isCoreLibraryDesugaringEnabled
    // above; flutter_local_notifications declares this requirement in its AAR metadata.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
