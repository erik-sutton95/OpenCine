// Optional reporting adapter (Swift twin: OpenCineSentryApple): appkit's reporting sink on the
// Sentry Android SDK, its gated OkHttp transport and the problem report's OkHttp upload. The one
// module that takes a third-party SDK; appkit and every other module never depend on it. An app
// adds it beside appkit and supplies only host values, its ProGuard UUID placeholder and its DSN
// (BuildConfig.SENTRY_DSN_ANDROID from the build-logic plugin com.opencapture.opencine.reporting).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.appkit.sentry"
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
    api(project(":appkit"))
    api(libs.sentry.android)
    implementation(libs.okhttp)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.json)
}
