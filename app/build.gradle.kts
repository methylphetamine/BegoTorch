plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.begonia.torchbridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.begonia.torchbridge"
        // API 26 (Android 8.0) is the floor: every ROM this targets is Treble
        // based, which is exactly the requirement for the flash-time SELinux
        // rule the TWRP package installs.
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "2.0.0"
        // No ABI splits, no NDK: the component is pure Kotlin.
        resourceConfigurations += listOf("en")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    sourceSets {
        getByName("main") {
            kotlin.srcDirs("src/main/kotlin")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            // The APK is installed by the TWRP package as a privileged system
            // app; it is signed with a stable key so that re-flashing an update
            // keeps the same signature (upgrades work in place).
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    lint {
        abortOnError = false
    }
}

// The TWRP package needs a predictable file name.
val apkOutputDir = layout.buildDirectory.dir("outputs/twrp").get().asFile

tasks.register<Copy>("stageTwrpApk") {
    description = "Copies the release APK to build/outputs/twrp/torchbridge.apk for packaging."
    dependsOn("assembleRelease")
    from(layout.buildDirectory.file("outputs/apk/release/app-release.apk"))
    into(apkOutputDir)
    rename { "torchbridge.apk" }
}
