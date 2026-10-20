// Shared app shell (Swift twin: OpenCineAppKit): the saved-camera store with its legacy
// mirrors, the connection model and the cameras and pair screens over the integration contract.
// Never depends on an integration or an app; apps list their integrations. JSON is org.json from
// android.jar (the real artifact backs the JVM tests).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.appkit"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
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
    api(project(":core"))
    api(project(":media"))
    api(project(":monitor-ui"))
    api(project(":multicam"))
    implementation(libs.kotlinx.coroutines.android)
    // AndroidX (catalog versions = the apps'): ContextCompat's not-exported battery receiver and
    // FileProvider for media sharing; the photo picker launcher of the problem report form.
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    testImplementation(testFixtures(project(":core")))
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.kotlin.test.junit)
}

// The saved-camera fixtures are shared with the Swift OpenCineAppKitTests (Fixtures/ at the
// repository root).
tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
