plugins {
    alias(libs.plugins.android.library)
}

// Composite consumers substitute this coordinate with the included project.
group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.insta360.luna"
    // 37 like OpenCineUI: no AAR-metadata exemption needed.
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    api(project(":insta360-shell"))
    api(project(":camera-vocabulary"))
    // The shared camera access-point join and Wi-Fi low-latency lock.
    implementation(project(":platform"))
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(testFixtures(project(":core")))
}

// The control-capability vectors the Swift Luna integration writes.
tasks.withType<Test>().configureEach {
    systemProperty("opencine.fixtures", rootProject.projectDir.resolve("../Fixtures").absolutePath)
}
