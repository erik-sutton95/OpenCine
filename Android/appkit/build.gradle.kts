// Shared app shell (Swift twin: OpenCineAppKit): the saved-camera store with its legacy
// mirrors, the connection model and the cameras and pair screens over the integration contract.
// Never depends on an integration or an app; apps list their integrations. JSON is org.json from
// android.jar (the real artifact backs the JVM tests).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.appkit"
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
    api(project(":core"))
    testImplementation(testFixtures(project(":core")))
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.json)
}

// The saved-camera fixtures are shared with the Swift OpenCineAppKitTests (Fixtures/ at the
// repository root).
tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
