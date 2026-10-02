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

rootProject.name = "opencineinsta360-android"

// Temporary: OpenCineCore is the sibling checkout ../OpenCineCore (pinned in opencine-pins.txt)
// until it is published; then this becomes the Maven coordinate alone. Named because Core's
// build directory is also called `Android`. A consumer that includes this build and Core under
// the same name shares one Core build.
includeBuild("../../OpenCineCore/Android") {
    name = "opencinecore"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
    }
}

include(":insta360-shell", ":insta360-luna")
