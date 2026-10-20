import com.android.build.api.artifact.ScopedArtifact
import com.android.build.api.variant.LibraryAndroidComponentsExtension
import com.android.build.api.variant.ScopedArtifacts
import java.net.URLClassLoader
import java.util.zip.ZipFile

// One classloader for AGP and the Kotlin plugins across all modules.
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// Public API snapshots: every module keeps its public API in <module>/api/<module>.api, which the
// atlas consumer index reads (atlas/README.md). A change that is meant runs
// `./gradlew updateKotlinAbi updateAndroidApi` and commits the files with it; CI runs
// `checkKotlinAbi checkAndroidApi`.
// - Kotlin/JVM modules: the Kotlin Gradle plugin's ABI validation (checkKotlinAbi, updateKotlinAbi).
// - Android library modules: with AGP's built-in Kotlin the plugin's dump finds no compilation and
//   records nothing (Kotlin 2.4.21, AGP 9.4.1), so dumpAndroidApi feeds the release variant's own
//   classes (Kotlin and Java, AGP's PROJECT-scoped CLASSES artifact) to the same JetBrains ABI tool
//   (org.jetbrains.kotlin:abi-tools at the Kotlin version). The format is the plugin's: public and
//   protected declarations, Kotlin `internal` and private ones left out from the Kotlin metadata.
subprojects {
    pluginManager.withPlugin("org.jetbrains.kotlin.jvm") { recordPublicApi() }
    pluginManager.withPlugin("com.android.library") { recordAndroidPublicApi() }
}

@OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
fun Project.recordPublicApi() {
    extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension> {
        abiValidation { referenceDumpDir.set(layout.projectDirectory.dir("api")) }
    }
}

val abiToolsVersion: String = libs.versions.kotlin.get()

fun Project.recordAndroidPublicApi() {
    val tools = configurations.create("androidApiTools") {
        isCanBeConsumed = false
        isCanBeResolved = true
    }
    dependencies.add(tools.name, "org.jetbrains.kotlin:abi-tools:$abiToolsVersion")
    val snapshot = layout.projectDirectory.file("api/${project.name}.api")
    val dump = tasks.register<AndroidApiDump>("dumpAndroidApi") {
        group = "verification"
        description = "Writes the release variant's public API to build/reports/android-api."
        abiTools.from(tools)
        output.set(layout.buildDirectory.file("reports/android-api/${project.name}.api"))
    }
    extensions.getByType(LibraryAndroidComponentsExtension::class.java).onVariants(
        extensions.getByType(LibraryAndroidComponentsExtension::class.java).selector().withBuildType("release"),
    ) { variant ->
        variant.artifacts.forScope(ScopedArtifacts.Scope.PROJECT)
            .use(dump)
            .toGet(ScopedArtifact.CLASSES, AndroidApiDump::jars, AndroidApiDump::dirs)
    }
    tasks.register<AndroidApiCheck>("checkAndroidApi") {
        group = "verification"
        description = "Fails when the public API differs from api/${project.name}.api."
        abiTools.from(tools)
        actual.set(dump.flatMap { it.output })
        expected.set(snapshot)
        expectedFiles.from(snapshot)
        moduleName.set(project.name)
    }
    tasks.register<Copy>("updateAndroidApi") {
        group = "verification"
        description = "Records the public API in api/${project.name}.api."
        from(dump.flatMap { it.output })
        into(layout.projectDirectory.dir("api"))
    }
}

/** The JetBrains ABI tool from [classpath], loaded apart from Gradle's own Kotlin. */
class AbiToolsHandle(classpath: Set<File>) : AutoCloseable {
    private val loader = URLClassLoader(classpath.map { it.toURI().toURL() }.toTypedArray(), ClassLoader.getPlatformClassLoader())
    private val api = loader.loadClass("org.jetbrains.kotlin.abi.tools.AbiTools")
    private val filters = loader.loadClass("org.jetbrains.kotlin.abi.tools.AbiFilters")
    private val tools: Any = api.getField("Companion").get(null).let { companion ->
        companion.javaClass.getMethod("getInstance", ClassLoader::class.java).invoke(companion, loader)
    }

    fun jvmDump(classFiles: List<File>): String {
        val empty = filters.getField("Companion").get(null).let { it.javaClass.getMethod("getEMPTY").invoke(it) }
        val out = StringBuilder()
        api.getMethod("printJvmDump", Appendable::class.java, Iterable::class.java, filters).invoke(tools, out, classFiles, empty)
        return out.toString()
    }

    /** A readable diff of two dump files, or null when they are the same. */
    fun diff(expected: File, actual: File): String? =
        api.getMethod("filesDiff", File::class.java, File::class.java).invoke(tools, expected, actual) as String?

    override fun close() = loader.close()
}

abstract class AndroidApiDump : DefaultTask() {
    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val jars: ListProperty<RegularFile>

    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val dirs: ListProperty<Directory>

    @get:Classpath
    abstract val abiTools: ConfigurableFileCollection

    @get:OutputFile
    abstract val output: RegularFileProperty

    @TaskAction
    fun dump() {
        val work = temporaryDir.apply { deleteRecursively(); mkdirs() }
        // Relative class path -> file. Not API: resources, the generated R and BuildConfig, and the
        // Compose compiler's ComposableSingletons holders, whose lambda getters are named by a hash
        // and would change the snapshot on unrelated edits.
        val classes = sortedMapOf<String, File>()
        fun keep(path: String) = path.endsWith(".class") && !path.startsWith("META-INF/") &&
            !Regex("(^|/)(R|R\\$[^/]*|BuildConfig|ComposableSingletons\\$[^/]*)\\.class$").containsMatchIn(path)
        dirs.get().forEach { dir ->
            dir.asFile.walkTopDown().filter { it.isFile }.forEach { file ->
                val path = file.relativeTo(dir.asFile).invariantSeparatorsPath
                if (keep(path)) classes[path] = file
            }
        }
        jars.get().forEachIndexed { index, jar ->
            ZipFile(jar.asFile).use { zip ->
                zip.entries().asSequence().filter { !it.isDirectory && keep(it.name) }.forEach { entry ->
                    val file = File(work, "$index/${entry.name}").apply { parentFile.mkdirs() }
                    zip.getInputStream(entry).use { input -> file.outputStream().use { input.copyTo(it) } }
                    classes[entry.name] = file
                }
            }
        }
        val text = AbiToolsHandle(abiTools.files).use { it.jvmDump(classes.values.toList()) }
        output.get().asFile.apply { parentFile.mkdirs() }.writeText(text)
    }
}

abstract class AndroidApiCheck : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val actual: RegularFileProperty

    // The snapshot may be missing (a new module): tracked as a file collection, read by path.
    @get:InputFiles @get:PathSensitive(PathSensitivity.NONE)
    abstract val expectedFiles: ConfigurableFileCollection

    @get:Internal
    abstract val expected: RegularFileProperty

    @get:Classpath
    abstract val abiTools: ConfigurableFileCollection

    @get:Input
    abstract val moduleName: Property<String>

    @TaskAction
    fun check() {
        val update = "run (cd Android && ./gradlew updateAndroidApi) and commit ${moduleName.get()}/api/${moduleName.get()}.api"
        val snapshot = expected.get().asFile
        if (!snapshot.isFile) throw GradleException("${moduleName.get()}: no public API snapshot; $update.")
        val diff = AbiToolsHandle(abiTools.files).use { it.diff(snapshot, actual.get().asFile) }
        if (!diff.isNullOrEmpty()) throw GradleException("${moduleName.get()}: unrecorded public API change; if it is intended, $update.\n$diff")
    }
}
