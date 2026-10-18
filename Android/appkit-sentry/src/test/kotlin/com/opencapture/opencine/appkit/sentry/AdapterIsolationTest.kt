package com.opencapture.opencine.appkit.sentry

import java.io.File
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The adapter is optional: no other OpenCine module depends on it, on the SDK or on OkHttp, or
 * imports them (Swift: `AppKitRules.sentryAdapterIsTheOnlyThirdPartyConsumer`).
 */
class AdapterIsolationTest {
    @Test
    fun onlyThisModuleTakesTheSdk() {
        val modules = File("..").listFiles().orEmpty()
            .filter { File(it, "build.gradle.kts").isFile && it.name != "appkit-sentry" }
        assertTrue(modules.size > 10)
        for (module in modules) {
            val build = File(module, "build.gradle.kts").readText()
            for (edge in listOf(":appkit-sentry", "libs.sentry", "libs.okhttp")) {
                assertFalse(build.contains(edge), "${module.name} names $edge")
            }
            File(module, "src").walk().filter { it.extension == "kt" }.forEach { file ->
                val imports = file.readLines().filter { it.startsWith("import ") }
                assertFalse(
                    imports.any {
                        it.startsWith("import io.sentry") || it.startsWith("import okhttp3") ||
                            it.startsWith("import com.opencapture.opencine.appkit.sentry")
                    },
                    file.path,
                )
            }
        }
    }
}
