// Camera controls (Swift twin: OpenCineCameraControls): the capture sheets, live chrome and gimbal
// views and their list logic over the camera vocabulary, shared by the apps. App composition, next
// to appkit: builds on camera-vocabulary, monitor-ui, appkit, core, media and motion, never on dji
// or another integration, an app or a third-party package. App differences arrive as host values.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.cameracontrols"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    api(project(":camera-vocabulary"))
    api(project(":monitor-ui"))
    api(project(":appkit"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.kotlin.test.junit)
}
