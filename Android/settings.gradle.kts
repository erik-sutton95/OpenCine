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
    // Wire-free relay framing, admission, control lease and stream policy.
    ":relay",
    ":relay-runtime", ":watch-runtime",
    // Deployed Nikon relay/watch schemas, isolated from camera sessions and JNI.
    ":nikon-wire",
    // UI: Compose monitor UI.
    ":monitor-ui",
    // Developer-only native conformance scenarios.
    ":app-ui-testing",
    // Developer-only instrumented-run setup: turns off Android's first-run hints (androidTest only).
    ":system-hints-testing",
    // Multicam engine (Kotlin/JVM).
    ":multicam",
    // Camera vocabulary (Kotlin/JVM): wire-free control values, status, model, zoom, tracking.
    ":camera-vocabulary",
    // DJI: BLE link, datalink, wire models, gimbal programs, CameraSession adapter (JNI facade DjiNative).
    ":dji",
    // Nikon: session contract, PTP-IP / USB PTP session over the Swift layer (JNI facade
    // NikonNative), live-view source, picker policy, CameraSession adapter.
    ":nikon",
    // Insta360: app shell contract (Kotlin/JVM) and the Luna adapter.
    ":insta360-shell", ":insta360-luna",
    // Shared app shell: saved cameras, connection model, cameras and pair screens.
    ":appkit",
    // Optional reporting adapter: appkit's reporting sink on the Sentry SDK (the one module with a
    // third-party SDK; nothing else here depends on it).
    ":appkit-sentry",
    // Camera controls: capture sheets, live chrome and gimbal views over the camera vocabulary.
    ":camera-controls",
    // Optional Compose/native picture composition above UI and native-runtime.
    ":appkit-native",
    // Frame.io: the one Android delivery owner (sign-in, upload, history, hop lease) over the
    // shared Swift wire (JNI facade FrameioNative).
    ":frameio",
    // Gyro: motion capture take policy, ring calibration, drift and arming over the shared Swift
    // wire (JNI facade GyroNative).
    ":gyro",
    // Media3 playback shared by the apps: player recipe, port, audio meter tap and playback owner.
    ":media3",
)
