// Plain Kotlin/JVM: no Android framework, so app modules can depend on it and its tests run on
// the JVM. Depends on OpenCineCore only (ImportRuleTests enforces it).
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
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(testFixtures(project(":core")))
    testImplementation(libs.kotlin.test.junit)
}
