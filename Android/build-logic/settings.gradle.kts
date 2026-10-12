// OpenCine's Gradle plugins for the apps' builds. An app includes this build through its
// pluginManagement: includeBuild("../../../OpenCine/Android/build-logic").
pluginManagement {
    repositories {
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
    versionCatalogs {
        create("libs") { from(files("../gradle/libs.versions.toml")) }
    }
}

rootProject.name = "opencine-build-logic"
