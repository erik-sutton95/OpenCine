// Media3 playback shared by the apps (app composition, next to appkit): the ExoPlayer recipe, the
// MonitorPlaybackPort over it, observed transport, the decoded-PCM audio meter tap and the playback
// owner. Media3 is AndroidX like appkit's androidx deps, at the apps' catalog version; apps keep
// only their DataSource (camera HTTP, Luna transfer, Nikon growing file).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.media3"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        explicitApi()
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
    }
}

dependencies {
    api(project(":appkit"))
    api(project(":native-runtime"))
    api(libs.androidx.media3.exoplayer)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
