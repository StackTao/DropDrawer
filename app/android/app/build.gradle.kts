plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigning = listOf(
    "DROPDRAWER_ANDROID_KEYSTORE",
    "DROPDRAWER_ANDROID_STORE_PASSWORD",
    "DROPDRAWER_ANDROID_KEY_ALIAS",
    "DROPDRAWER_ANDROID_KEY_PASSWORD",
).map(System::getenv)
val hasReleaseSigning = releaseSigning.all { !it.isNullOrBlank() }
require(hasReleaseSigning || releaseSigning.all { it.isNullOrBlank() }) {
    "Configure all four DropDrawer Android signing variables together."
}

android {
    namespace = "com.dropdrawer.dropdrawer_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dropdrawer.dropdrawer_app"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    if (hasReleaseSigning) {
        signingConfigs.create("distribution") {
            storeFile = file(releaseSigning[0]!!)
            storePassword = releaseSigning[1]
            keyAlias = releaseSigning[2]
            keyPassword = releaseSigning[3]
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "distribution" else "debug")
        }
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
