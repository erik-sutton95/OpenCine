// One classloader for AGP and the Kotlin plugin across both modules.
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
}
