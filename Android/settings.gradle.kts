pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// One Gradle build for every OpenCine Android module. Each module keeps its published
// coordinate com.opencapture.opencine:<module> (group and version are set in the module), so
// an app's composite build substitutes the same coordinates it used before. Apps include this
// build under the name `opencine` (its directory is called `Android`, like the apps' builds).
rootProject.name = "opencine-android"

include(
    // Core: Kotlin/JVM contracts (+ test fixtures), media policy, live-view MediaCodec decoder,
    // native Vulkan renderer and effects runtime.
    ":core", ":media", ":platform", ":decoder", ":vulkan", ":native-runtime",
    // UI: Compose monitor UI.
    ":monitor-ui",
    // Multicam engine (Kotlin/JVM).
    ":multicam",
    // DJI: BLE link, datalink, wire models, gimbal programs, CameraSession adapter (JNI facade DjiNative).
    ":dji",
    // Nikon: session contract, PTP-IP / USB PTP session over the Swift layer (JNI facade
    // NikonNative), live-view source, picker policy, CameraSession adapter.
    ":nikon",
    // Insta360: app shell contract (Kotlin/JVM) and the Luna adapter.
    ":insta360-shell", ":insta360-luna",
    // Shared app shell: saved cameras, connection model, cameras and pair screens.
    ":appkit",
)
