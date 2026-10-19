// One classloader for AGP and the Kotlin plugins across all modules.
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// Public API snapshots: every module an app links keeps its Kotlin public API in
// <module>/api/<module>.api. `checkKotlinAbi` fails on an unrecorded change; a change that is
// meant runs `./gradlew updateKotlinAbi` and commits the files with it. The atlas consumer
// index reads them (atlas/README.md). Developer-only test modules have no consumers to protect.
val apiSnapshotExempt = setOf("app-ui-testing", "system-hints-testing")
subprojects {
    if (name in apiSnapshotExempt) return@subprojects
    pluginManager.withPlugin("org.jetbrains.kotlin.jvm") { recordPublicApi() }
    pluginManager.withPlugin("com.android.library") { recordPublicApi() }
}

@OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
fun Project.recordPublicApi() {
    val kotlin = extensions.getByName("kotlin") as ExtensionAware
    kotlin.extensions.configure<org.jetbrains.kotlin.gradle.dsl.abi.AbiValidationExtension>("abiValidation") {
        enabled.set(true)
    }
}
