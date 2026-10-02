// Native Vulkan live-feed renderer (`libopc_vulkan.so`), moved unchanged from the Pocket app:
// imported decoder AHardwareBuffer, GPU grade, scopes, grab-pass glass, swapchain present.
// The Kotlin facade keeps its original class name, com.opencapture.openpocketcine.feed.OpcVulkan,
// because the 21 exported JNI symbols (Java_com_opencapture_openpocketcine_feed_OpcVulkan_*) are
// derived from it. The session that drives it (MediaCodec, ImageReader, scopes) stays in the app.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.vulkan"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 29
        // ponytail: arm64-v8a is the only qualified ABI (plan 10.4); add others after a device run.
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake { arguments += "-DANDROID_STL=c++_static" }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}
