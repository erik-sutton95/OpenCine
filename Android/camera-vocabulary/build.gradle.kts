// Camera vocabulary (Kotlin side of OpenCineCameraVocabulary): the wire-free camera control
// values, status, model, zoom, tracking and recovery types that DJI and Insta360 apps share.
// Plain Kotlin/JVM on core, media and the motion package; no UI, integration, app or wire code.
// Raw values are the stored values; the DJI wire members stay in dji as extensions.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

// ponytail: explicit API mode off so the moved dji code keeps its shape, as in media.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    api(project(":core"))
    api(project(":media"))
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

// camfov-vectors.tsv is shared with the Swift CamFovVectorTests (Fixtures/ at the repository root).
tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
