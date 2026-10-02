pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = "opencinemulticam-android"

// Temporary: OpenCineCore is the sibling checkout ../OpenCineCore (pinned in opencine-pins.txt)
// until it is published; then this becomes the Maven coordinate alone. Named because Core's
// build directory is also called `Android`.
includeBuild("../../OpenCineCore/Android") {
    name = "opencinecore"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
    }
}

include(":multicam")
