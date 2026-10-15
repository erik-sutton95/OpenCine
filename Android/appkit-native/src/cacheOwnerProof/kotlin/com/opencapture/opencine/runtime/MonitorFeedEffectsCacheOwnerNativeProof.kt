package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorLUTCubeCache
import com.opencapture.openpocketcine.feed.OpcVulkan
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** SIMULATED input through the actual staged JNI and actual GLES/Vulkan; shared by all app bindings. */
class MonitorFeedEffectsCacheOwnerNativeProof(private val binding: Binding) {
    interface PlanOwner : AutoCloseable {
        fun plan(): FeedEffectsRenderPlan
    }
    interface Binding {
        val context: Context
        fun nativeVersion(): String
        fun packedCube(seed: Int): ByteArray?
        val vectorOrdinals: IntRange
        fun vectorBakers(): Map<String, (Int) -> ByteArray?>
        fun planOwner(): PlanOwner
        fun compositionScene(): CompositionScene
    }

    /** Test transport supplied by the composition layer, with no UI import or new runtime edge. */
    class CompositionScene(
        val snapshot: () -> List<Triple<Any, Any, FeedEffectsRenderPlan>>,
        val retiredPlan: (Any) -> FeedEffectsRenderPlan,
        val command: (String) -> Unit,
        private val retire: () -> Unit,
    ) : AutoCloseable { override fun close() = retire() }

    fun actualComposeCacheOwnersSurviveCoverageRotationDetachAndFinalRetirement() {
        val scene = binding.compositionScene()
        fun cube(plan: FeedEffectsRenderPlan) = plan.falseColorPaint ?: plan.lutCube
        fun hasNoCubes(plan: FeedEffectsRenderPlan) =
            plan.lutCube == null && plan.falseColorPaint == null && plan.falseColorWeight == null
        try {
            val initial = scene.snapshot()
            check(initial.size == 2)
            val first = initial[0]
            val second = initial[1]
            val firstCube = requireNotNull(cube(first.third))
            val secondCube = requireNotNull(cube(second.third))
            check(first.second !== second.second && firstCube.rgba !== secondCube.rgba)
            check(firstCube.rgba.size == 1_048_576 && secondCube.rgba.size == 1_048_576)
            check(firstCube.rgba.contentEquals(secondCube.rgba))
            val beforeGles = gles(first.third)
            val beforeVulkan = vulkan(first.third)
            check(!beforeGles.contentEquals(gles(FeedEffectsRenderPlan.IDENTITY)))
            check(!beforeVulkan.contentEquals(vulkan(FeedEffectsRenderPlan.IDENTITY)))
            for (action in listOf("cover", "uncover", "rotate", "detach")) {
                scene.command(action)
                val current = scene.snapshot()
                check(current.size == 2)
                check(current[0].first === first.first && current[1].first === second.first)
                check(current[0].second === first.second && current[1].second === second.second) {
                    "Actual remembered facade changed on $action"
                }
                check(cube(current[0].third) === firstCube && cube(current[1].third) === secondCube) {
                    "Actual cache was closed or replaced on $action"
                }
            }
            scene.command("retire-first")
            check(hasNoCubes(scene.retiredPlan(first.first))) { "Disposed actual composition refilled its facade" }
            val retained = scene.snapshot().single()
            check(retained.first === second.first && retained.second === second.second)
            check(cube(retained.third) === secondCube)
            check(beforeGles.contentEquals(gles(first.third)))
            check(beforeVulkan.contentEquals(vulkan(first.third)))
            scene.command("replace-first")
            val replacement = scene.snapshot()
            check(replacement.size == 2)
            val successor = replacement[0]
            check(successor.first !== first.first && successor.second !== first.second)
            val successorCube = requireNotNull(cube(successor.third))
            check(successorCube.rgba !== firstCube.rgba && successorCube.rgba.contentEquals(firstCube.rgba))
            check(replacement[1].second === second.second && cube(replacement[1].third) === secondCube)
            check(hasNoCubes(scene.retiredPlan(first.first))) { "Retired predecessor admitted after successor" }
            check(cube(scene.snapshot()[0].third) === successorCube)
            scene.command("unmount")
            check(hasNoCubes(scene.retiredPlan(second.first)) && hasNoCubes(scene.retiredPlan(successor.first)))
            check(beforeGles.contentEquals(gles(first.third)))
            check(beforeVulkan.contentEquals(vulkan(first.third)))
        } finally { scene.close() }
    }

    fun actualNativeBytesMatchOldStagedLibrary(referenceMode: String) {
        check(binding.nativeVersion().isNotBlank()) { "Actual staged Swift library is required" }
        check(referenceMode == "record" || referenceMode == "verify")
        val directory = File(binding.context.getExternalFilesDir(null), "cache-owner-reference")
        if (referenceMode == "record") check(directory.mkdirs() || directory.isDirectory)
        for (ordinal in binding.vectorOrdinals) for ((component, bake) in binding.vectorBakers()) {
            val name = "$component-$ordinal"
            val actual = requireNotNull(bake(ordinal)) { "Actual JNI rejected $name" }
            check(actual.size == 1_048_576) { "$name native count ${actual.size}" }
            val reference = File(directory, "$name.rgba")
            if (referenceMode == "record") {
                reference.writeBytes(actual)
            } else {
                check(reference.isFile) { "Old staged-library reference missing for $name" }
                check(actual.contentEquals(reference.readBytes())) { "Whole actual JNI bytes changed for $name" }
            }
        }
    }

    fun actualNativePayloadsObeyEightEntryLruAndImmediateRetirement() {
        val cache = MonitorLUTCubeCache()
        val other = MonitorLUTCubeCache()
        val calls = mutableMapOf<Int, Int>()
        fun read(seed: Int): MonitorLUTCube? = cache.value("native-$seed") {
            calls[seed] = (calls[seed] ?: 0) + 1
            MonitorLUTCube.fromPacked(requireNotNull(binding.packedCube(seed)))
        }
        try {
            val first = requireNotNull(read(0))
            repeat(7) { read(it + 1) }
            check(first.rgba.size == 1_048_576)
            check(read(0) === first)
            read(8)
            check(read(0) === first && calls[0] == 1)
            read(1)
            check(calls[1] == 2 && calls.values.sum() == 10) { "Actual eight-entry LRU was not exercised" }
            val separate = requireNotNull(other.value("native-0") {
                MonitorLUTCube.fromPacked(requireNotNull(binding.packedCube(0)))
            })
            check(separate.rgba !== first.rgba)
            check(separate.rgba.contentEquals(first.rgba))
            cache.close()
            check(cache.value("native-0") { error("Retired cache admitted a native bake") } == null)
            check(other.value("native-0") { error("Other owner lost its payload") } === separate)
        } finally { cache.close(); other.close() }
    }

    fun enteredActualNativeBakeCannotRefillRetiredOwner() {
        val retired = MonitorLUTCubeCache()
        val current = MonitorLUTCubeCache()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val old = pool.submit<MonitorLUTCube?> {
                retired.value("native") {
                    val actual = MonitorLUTCube.fromPacked(requireNotNull(binding.packedCube(0)))
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                    actual
                }
            }
            check(entered.await(90, TimeUnit.SECONDS)) { "Actual native bake never entered" }
            pool.submit { retired.close() }.get(2, TimeUnit.SECONDS)
            check(pool.submit<MonitorLUTCube?> {
                retired.value("native") { error("Closed owner admitted work") }
            }.get(2, TimeUnit.SECONDS) == null)
            val successor = current.value("native") {
                MonitorLUTCube.fromPacked(requireNotNull(binding.packedCube(1)))
            }
            release.countDown()
            check(old.get(10, TimeUnit.SECONDS) == null)
            check(current.value("native") { error("Retired completion erased successor") } === successor)
        } finally { release.countDown(); retired.close(); current.close(); pool.shutdownNow() }
    }

    fun actualFacadePlansRemainRenderableAfterOnlyTheirCacheRetires() {
        val a = binding.planOwner()
        val b = binding.planOwner()
        try {
            val borrowed = a.plan()
            val independent = b.plan()
            fun cube(plan: FeedEffectsRenderPlan) = plan.falseColorPaint ?: plan.lutCube
            val first = requireNotNull(cube(borrowed)) { "Real facade returned no false-color payload" }
            val second = requireNotNull(cube(independent))
            check(first.size == 64 && second.size == 64)
            check(first.rgba !== second.rgba) { "Facade caches share a process root" }
            check(cube(a.plan()) === first && cube(b.plan()) === second)
            val beforeGles = gles(borrowed)
            val beforeVulkan = vulkan(borrowed)
            check(!beforeGles.contentEquals(gles(FeedEffectsRenderPlan.IDENTITY))) { "Actual GLES grade was not visible" }
            check(!beforeVulkan.contentEquals(vulkan(FeedEffectsRenderPlan.IDENTITY))) { "Actual Vulkan grade was not visible" }
            a.close()
            check(cube(a.plan()) == null) { "Actual retired facade refilled" }
            check(cube(b.plan()) === second) { "Retiring one facade erased another" }
            check(beforeGles.contentEquals(gles(borrowed))) { "Escaped plan changed actual GLES pixels" }
            check(beforeVulkan.contentEquals(vulkan(borrowed))) { "Escaped plan changed actual Vulkan pixels" }
            check(first.rgba.contentEquals(second.rgba))
        } finally { a.close(); b.close() }
    }

    private fun input() = InspectorPreviewFrame(17, 13, ByteArray(17 * 13 * 4) { index ->
        val pixel = index / 4
        val x = pixel % 17
        val y = pixel / 17
        when (index % 4) {
            0 -> (x * 29 + y * 11) % 256
            1 -> if (x % 4 == 0) 255 else (x * 7 + y * 37) % 256
            2 -> if (y % 3 == 0) 0 else (x * 47 + y * 13) % 256
            else -> 255
        }.toByte()
    })

    private fun gles(plan: FeedEffectsRenderPlan): IntArray {
        val renderer = InspectorPreviewRenderer { NativeGlBackend.create(it) }
        try {
            val bitmap = renderer.render(binding.context, plan, input())
            try {
                return IntArray(bitmap.width * bitmap.height).also {
                    bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                }
            } finally { bitmap.recycle() }
        } finally { renderer.close() }
    }

    private fun vulkan(plan: FeedEffectsRenderPlan): ByteArray {
        check(OpcVulkan.isAvailable && OpcVulkan.nativeProbeBitmap()) { "Actual Vulkan library/device is required" }
        val native = OpcVulkan.nativeCreateBitmap()
        check(native != 0L)
        val thread = HandlerThread("cache-owner-vulkan-proof").apply { start() }
        val pixels = LinkedBlockingQueue<ByteArray>()
        val frame = input()
        val reader = ImageReader.newInstance(frame.width, frame.height, PixelFormat.RGBA_8888, 4,
            HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_CPU_READ_OFTEN)
        reader.setOnImageAvailableListener({ source ->
            source.acquireNextImage()?.use { image ->
                val plane = image.planes.single()
                check(plane.pixelStride == 4)
                val result = ByteArray(image.width * image.height * 4)
                for (y in 0 until image.height) {
                    val row = plane.buffer.duplicate()
                    row.position(y * plane.rowStride)
                    row.get(result, y * image.width * 4, image.width * 4)
                }
                pixels.add(result)
            }
        }, Handler(thread.looper))
        val bitmap = Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.setPixels(IntArray(frame.width * frame.height) { pixel ->
                val offset = pixel * 4
                Color.argb(255, frame.rgba[offset].toInt() and 255,
                    frame.rgba[offset + 1].toInt() and 255, frame.rgba[offset + 2].toInt() and 255)
            }, 0, frame.width, 0, 0, frame.width, frame.height)
            check(OpcVulkan.nativeAttachBitmapWindow(native, reader.surface))
            OpcVulkan.nativeResize(native, frame.width, frame.height)
            check(OpcVulkan.nativeConfigureBitmap(native, bitmapVulkanUniforms(plan, false, false),
                plan.lutCube?.size ?: 0, plan.lutCube?.rgba,
                plan.falseColorPaint?.size ?: 0, plan.falseColorPaint?.rgba,
                plan.falseColorWeight?.size ?: 0, plan.falseColorWeight?.rgba))
            check(OpcVulkan.nativeSetBitmapPaused(native, false))
            check(OpcVulkan.nativeSubmitBitmap(native, bitmap))
            return requireNotNull(pixels.poll(10, TimeUnit.SECONDS)) { "Actual Vulkan present missing" }
        } finally {
            OpcVulkan.nativeDestroy(native); bitmap.recycle(); reader.close(); thread.quitSafely()
        }
    }
}
