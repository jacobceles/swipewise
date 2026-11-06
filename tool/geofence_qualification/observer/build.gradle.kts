plugins {
    id("com.android.application") version "9.4.1"
}

// Standalone test helper only. No Flutter, Firebase, shipping signing or flavors.
android {
    namespace = "com.appsoflife.swipewise.qualification.observer"
    compileSdk = 37
    compileSdkMinor = 0
    defaultConfig {
        applicationId = "com.appsoflife.swipewise.qualification.observer"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "qualification-observer-v1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    signingConfigs {
        getByName("debug") {
            storeFile = file(providers.gradleProperty("observerKeystore").get())
            storePassword = "android"
            keyAlias = "qualification"
            keyPassword = "android"
        }
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.4.0")
    // Match already-cached app dependencies, rather than downloading the old
    // AndroidX/Kotlin minima in GMS's transitive graph for this standalone app.
    implementation("androidx.core:core:1.19.1")
    implementation("androidx.fragment:fragment:1.7.1")
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.4.21")
}
