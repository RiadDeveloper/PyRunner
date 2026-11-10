import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config (key.properties is generated at build time;
// if it is missing, the debug key is used so the build still works).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.pyrunner.pyrunner"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.pyrunner.pyrunner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Chaquopy requires minSdk 24.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Python 3.12+ is 64-bit only, so only 64-bit ABIs are supported.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Signing with the debug keys for now, so `flutter run --release` works.
                signingConfigs.getByName("debug")
            }
        }
    }
}

chaquopy {
    defaultConfig {
        // Latest Python with broad wheel support (3.13.16 in Chaquopy 17.2.0).
        // Python 3.15 exists but has very few Android wheels yet.
        version = "3.13"
        buildPython("/home/hatch/workspace/tools/python-3.13/bin/python3.13")
        // Bundled so the sample project can `import requests` offline.
        // pycryptodome 3.21.0 is the newest version with a Chaquopy
        // Android wheel (cp313, arm64-v8a + x86_64): PyPI 4.x has no
        // Android wheel, so `pip install pycryptodome>=3.20.0` on device
        // falls back to the sdist and fails to build (no C compiler).
        // Bundling it means `from Crypto.Cipher import AES` works with
        // no on-device install at all (v1.0.3).
        pip {
            install("requests")
            install("pycryptodome==3.21.0")
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
