plugins {
    `kotlin-dsl`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    // The Android Gradle plugin is the app's own (same version, from the shared catalog).
    compileOnly("com.android.tools.build:gradle-api:${libs.versions.agp.get()}")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:$embeddedKotlinVersion")
}

gradlePlugin {
    plugins {
        register("reporting") {
            id = "com.opencapture.opencine.reporting"
            implementationClass = "com.opencapture.opencine.gradle.ReportingPlugin"
        }
    }
}
