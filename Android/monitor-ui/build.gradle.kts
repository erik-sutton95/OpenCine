plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

// Composite consumers substitute this coordinate with the included project.
group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.monitorui"
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
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    api(project(":media"))
    api(platform(libs.compose.bom))
    api(libs.compose.material3)
    testImplementation(libs.kotlin.test.junit)
    // Instrumented input tests of the shared components (connectedAndroidTest on a device). AndroidX
    // test artifacts and activity-compose for the test host activity; androidTest only.
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.activity.compose)
    androidTestImplementation(libs.kotlin.test.junit)
    androidTestImplementation(project(":camera-controls"))
    // The test host hides the system bars; this library's run listener keeps Android's full
    // screen tutorial from covering it.
    androidTestImplementation(project(":system-hints-testing"))
}

// SharedUIRulesTest scans the app shell; all fixture vectors share the Swift test inputs.
tasks.withType<Test>().configureEach {
    inputs.dir(rootDir.resolve("appkit/src/main"))
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
