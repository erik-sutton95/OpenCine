// Gyro for every app's Android shell (Swift twin: OpenCineGyro, through the JNI facade
// GyroNative exported by OpenCineGyroAndroid). The shared wire owns take segmentation, GCSV
// encoding, ring calibration, drift detection and session arming; the platform owns sensors,
// files, camera observations and the UI. Apps supply a GyroCameraAdapter. GyroNative's class
// name is part of the native symbol names (consumer-rules.pro keeps it).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

val repositoryRoot: File = projectDir.resolve("../..")

android {
    namespace = "com.opencapture.opencine.gyro"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
    // FakeGyroNative, FakeGyroCameraAdapter and FakeMotionSensors for this module's JVM tests and
    // for UI tests in the modules that render the shared gyro screens.
    testFixtures { enable = true }
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
    testFixturesApi(libs.kotlinx.coroutines.core)
}

// The take-status vectors are shared with the Swift OpenCineGyroTests (Fixtures/ at the
// repository root).
tasks.withType<Test>().configureEach {
    systemProperty("opencine.repositoryRoot", repositoryRoot.canonicalPath)
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
