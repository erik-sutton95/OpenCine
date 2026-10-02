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
    defaultConfig { minSdk = 29 }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    api(platform(libs.compose.bom))
    api(libs.compose.material3)
    testImplementation(libs.kotlin.test.junit)
}

// SharedUIRulesTest also scans the app shell sources.
tasks.withType<Test>().configureEach { inputs.dir(rootDir.resolve("appkit/src/main")) }
