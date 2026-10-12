package com.opencapture.opencine.gradle

import com.android.build.api.variant.AndroidComponentsExtension
import com.android.build.api.variant.BuildConfigField
import com.android.build.api.variant.Variant
import java.io.StringReader
import java.util.Properties
import org.gradle.api.Plugin
import org.gradle.api.Project

private const val DSN = "SENTRY_DSN_ANDROID"

/**
 * The reporting adapter's DSN for an Android app or library module (`:appkit-sentry`'s Gradle
 * twin): `BuildConfig.SENTRY_DSN_ANDROID`. A non-empty `SENTRY_DSN_ANDROID` environment value (the
 * CI secret) wins; otherwise `SENTRY_DSN_ANDROID` from the repository's ignored
 * `.local/reliability.properties` (local debug builds); otherwise empty, which leaves reporting
 * unavailable. Apply after the Android plugin in a module that enables `buildConfig`; the Gradle
 * root is the repository's `Apps/Android`.
 */
class ReportingPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val providers = project.providers
        val localProperties =
            project.rootProject.layout.projectDirectory.file("../../.local/reliability.properties")
        val field =
            providers.environmentVariable(DSN).orElse("")
                .zip(providers.fileContents(localProperties).asText.orElse("")) { env, file ->
                    val literal = javaStringLiteral(sentryDsn(env, file))
                    BuildConfigField("String", literal, "optional Sentry Android DSN")
                }
        project.extensions.getByType(AndroidComponentsExtension::class.java)
            .onVariants { variant: Variant -> variant.buildConfigFields?.put(DSN, field) }
    }
}

/** The environment value when non-empty, else the local properties file's value, both trimmed. */
internal fun sentryDsn(environment: String, localProperties: String): String =
    environment.trim().ifEmpty {
        Properties().apply { load(StringReader(localProperties)) }
            .getProperty(DSN)?.trim().orEmpty()
    }

internal fun javaStringLiteral(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
