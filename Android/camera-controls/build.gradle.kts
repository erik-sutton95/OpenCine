// Camera controls (Swift twin: OpenCineCameraControls): the capture sheets, live chrome and gimbal
// views and their list logic over the camera vocabulary, shared by the apps. App composition, next
// to appkit: builds on camera-vocabulary, monitor-ui, appkit, core, media, motion and gyro, never
// on dji or another integration, an app or a third-party package. App differences arrive as host
// values.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

// The platform's third-party notices and the shared UI's font and icon license texts, staged as
// Java resources from the repository files the Swift twin bundles (MonitorUI Resources), so every
// app's Licenses page shows those files themselves. Concrete path so the SourceSet API accepts it.
val repositoryRoot: File = projectDir.resolve("../..")
val stagedLegalResourcesDirectory: File = layout.buildDirectory.get().asFile.resolve("generated/legalResources")
val stageLegalResources = tasks.register<Copy>("stageLegalResources") {
    group = "build"
    description = "Stage OpenCine's third-party notices and UI license texts into the library resources."
    into(stagedLegalResourcesDirectory.resolve("opencine/legal"))
    from(repositoryRoot.resolve("THIRD-PARTY-NOTICES.md"))
    from(repositoryRoot.resolve("Sources/MonitorUI/Resources")) {
        include("Fonts/OFL-Sora.txt", "Icons/lucide/LICENSE.txt", "Icons/assist/LICENSE-Tabler.txt")
    }
}

android {
    sourceSets { getByName("main").resources.srcDir(stagedLegalResourcesDirectory) }
    namespace = "com.opencapture.opencine.cameracontrols"
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
    api(project(":camera-vocabulary"))
    api(project(":monitor-ui"))
    api(project(":appkit"))
    api(project(":gyro"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(testFixtures(project(":core")))
    testImplementation(libs.kotlinx.coroutines.test)
    // GalleryOpeningAdmissionTest: the shared gallery hosted in a real activity on a device.
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(testFixtures(project(":core")))
    // GyroScreensTest: GyroFeatureHost over a coordinator built on the gyro fakes.
    androidTestImplementation(testFixtures(project(":gyro")))
}

// The link chip vectors are shared with the Swift OpenCineCameraVocabularyTests (Fixtures/ at the
// repository root).
tasks.named("preBuild").configure { dependsOn(stageLegalResources) }

tasks.withType<Test>().configureEach {
    systemProperty("opencine.repositoryRoot", repositoryRoot.canonicalPath)
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
