// Portable media runtime policy (Kotlin side of OpenCineMedia): H.26x NAL math, decoder
// admission/hold/error policy and present timing. Plain Kotlin/JVM; MediaCodec, Surface and the
// Vulkan renderer stay in the app modules.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

// ponytail: explicit API mode off so the moved Pocket/Insta code keeps its shape; turn it on
// once the module's public surface settles.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    api(project(":core"))
    testImplementation(libs.kotlin.test.junit)
}

// The NAL vectors are shared with the Swift tests (Fixtures/ at the repository root).
tasks.test {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
