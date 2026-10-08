// Plain Kotlin/JVM: no Android framework, so app modules can depend on it and its
// tests run on the JVM. Fakes ship as test fixtures for consumers' unit tests.
plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-test-fixtures`
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
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(testFixtures(project(":core")))
}
