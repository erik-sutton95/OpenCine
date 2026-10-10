// Portable relay policy mirrors OpenCineRelay. SDK sockets and native encoders stay above it.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    api(project(":core"))
    testImplementation(libs.kotlin.test.junit)
}
