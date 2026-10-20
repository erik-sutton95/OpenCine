// One classloader for AGP and the Kotlin plugins across all modules.
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// Public API snapshots: every Kotlin/JVM module keeps its public API in <module>/api/<module>.api.
// `checkKotlinAbi` fails on an unrecorded change; a change that is meant runs
// `./gradlew updateKotlinAbi` and commits the files with it. The atlas consumer index reads them
// (atlas/README.md). Android library modules are not covered yet: with AGP's built-in Kotlin the
// Kotlin plugin's ABI dump finds no compilation and records nothing (Kotlin 2.4.21, AGP 9.4.1).
subprojects {
    pluginManager.withPlugin("org.jetbrains.kotlin.jvm") { recordPublicApi() }
}

@OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
fun Project.recordPublicApi() {
    extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension> {
        abiValidation { referenceDumpDir.set(layout.projectDirectory.dir("api")) }
    }
}
