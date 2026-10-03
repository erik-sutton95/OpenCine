// Plain Kotlin/JVM: the app shell compiles against it without the Luna adapter.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Composite consumers substitute this coordinate with the included project.
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
    }
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    // CoreSessionSource hands out an OpenCineCore CameraSession.
    api(project(":core"))
    // The real connected-camera media producer exposes portable Media services.
    api(project(":media"))
}
