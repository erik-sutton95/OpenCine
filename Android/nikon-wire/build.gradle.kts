// Deployed Nikon relay/watch schemas without camera sessions, JNI or transport owners.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.nikonwire"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            allWarningsAsErrors.set(true)
        }
    }
}

dependencies {
    api(project(":core"))
    // Android supplies org.json; local tests exercise the same codec with the existing fixture library.
    testImplementation(libs.json)
    testImplementation(libs.kotlin.test.junit)
}
