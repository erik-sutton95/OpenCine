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
}

// SharedUIRulesTest also scans the app shell sources.
tasks.withType<Test>().configureEach { inputs.dir(rootDir.resolve("appkit/src/main")) }
