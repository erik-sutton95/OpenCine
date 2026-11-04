package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The landscape feed frame: a picture taller than 16:9 (a 3:2 or 4:3 still) is scaled down to fit
 * inside the 16:9 region a video picture fills, keeping the video's black bars top and bottom and
 * every control where video has it. Same table as Swift `LandscapeFeedFrameTests`.
 */
class LandscapeFeedFrameTest {
    private data class Screen(
        val name: String, val width: Float, val height: Float, val leading: Float, val bottom: Float,
    ) {
        fun layout(aspect: Float) = MonitorLayoutPolicy.fieldMonitor(
            width, height, safeLeading = leading, safeBottom = bottom,
            sourceAspect = aspect, valueCount = 9,
        )
    }

    private val iPad11 = Screen("iPad 11-inch", 1210f, 834f, 0f, 20f)
    private val iPadClassic = Screen("iPad 4:3", 1024f, 768f, 0f, 20f)
    private val androidTablet = Screen("Android tablet", 1280f, 800f, 0f, 0f)
    private val iPhone = Screen("iPhone 16 Pro", 874f, 402f, 62f, 21f)
    private val androidPhone = Screen("Android phone", 915f, 412f, 30f, 0f)
    private val screens = listOf(iPad11, iPadClassic, androidTablet, iPhone, androidPhone)

    private val table: List<Triple<Screen, Float, MonitorRect>> = listOf(
        // Tablets: one 16:9 frame; a taller picture fits inside it, pillarboxed.
        Triple(iPad11, 16f / 9f, MonitorRect(0f, 76.6875f, 1210f, 680.625f)),
        Triple(iPad11, 3f / 2f, MonitorRect(94.53125f, 76.6875f, 1020.9375f, 680.625f)),
        Triple(iPad11, 4f / 3f, MonitorRect(151.25f, 76.6875f, 907.5f, 680.625f)),
        Triple(iPadClassic, 16f / 9f, MonitorRect(0f, 96f, 1024f, 576f)),
        Triple(iPadClassic, 3f / 2f, MonitorRect(80f, 96f, 864f, 576f)),
        Triple(iPadClassic, 4f / 3f, MonitorRect(128f, 96f, 768f, 576f)),
        Triple(androidTablet, 16f / 9f, MonitorRect(0f, 40f, 1280f, 720f)),
        Triple(androidTablet, 3f / 2f, MonitorRect(100f, 40f, 1080f, 720f)),
        Triple(androidTablet, 4f / 3f, MonitorRect(160f, 40f, 960f, 720f)),
        // Phones are wider than 16:9: the frame is already full height, so the rule leaves every
        // picture where it was.
        Triple(iPhone, 16f / 9f, MonitorRect(79.666667f, 0f, 714.666667f, 402f)),
        Triple(iPhone, 3f / 2f, MonitorRect(135.5f, 0f, 603f, 402f)),
        Triple(iPhone, 4f / 3f, MonitorRect(169f, 0f, 536f, 402f)),
        Triple(androidPhone, 16f / 9f, MonitorRect(91.277778f, 0f, 732.444444f, 412f)),
        Triple(androidPhone, 3f / 2f, MonitorRect(148.5f, 0f, 618f, 412f)),
        Triple(androidPhone, 4f / 3f, MonitorRect(182.833333f, 0f, 549.333333f, 412f)),
    )

    private fun near(expected: Float, actual: Float, label: String) =
        assertTrue(abs(expected - actual) < 0.01f, "$label: expected $expected, was $actual")

    @Test
    fun pictureFitsInsideTheVideoFrame() {
        for ((screen, aspect, expected) in table) {
            val picture = screen.layout(aspect).picture
            val label = "${screen.name} aspect $aspect"
            near(expected.x, picture.x, "$label x")
            near(expected.y, picture.y, "$label y")
            near(expected.width, picture.width, "$label width")
            near(expected.height, picture.height, "$label height")
            assertTrue(abs(picture.width / picture.height - aspect) < 0.001f, "$label keeps its shape")
        }
    }

    /**
     * A still keeps the video's bars and controls: only the picture inside the frame changes. On a
     * tablet the status row stays where video has it, over the top bar.
     */
    @Test
    fun tallerPictureKeepsEveryControlWhereVideoHasIt() {
        for (screen in screens) {
            val video = screen.layout(16f / 9f)
            for (aspect in listOf(3f / 2f, 4f / 3f)) {
                val still = screen.layout(aspect)
                val label = "${screen.name} $aspect"
                near(video.picture.y, still.picture.y, "$label top bar")
                near(video.picture.maxY, still.picture.maxY, "$label bottom bar")
                near(video.picture.midX, still.picture.midX, "$label centred")
                if (still.tablet) {
                    assertEquals(video.status, still.status, "$label status row")
                } else {
                    // A phone's picture runs the full height: the status row stays on the picture.
                    near(still.picture.x + 12f, still.status.x, "$label status row")
                }
                assertEquals(video.values, still.values, "$label camera values")
                assertEquals(video.record, still.record, "$label record")
                assertEquals(video.settings, still.settings, "$label settings")
                assertEquals(video.media, still.media, "$label media")
                assertEquals(video.lock, still.lock, "$label lock")
                assertEquals(video.assists, still.assists, "$label assists")
                assertEquals(video.stick, still.stick, "$label joystick")
            }
        }
    }

    /**
     * The recenter key (and AE unlock beside it) without a motion cluster sits on the scaled
     * picture, inside its trailing bottom corner, so it never floats in the black pillarbox.
     */
    @Test
    fun recenterSitsOnTheScaledPicture() {
        for (screen in listOf(iPad11, androidTablet)) {
            val layout = screen.layout(3f / 2f)
            val reset = layout.focusReset(motionCluster = false)
            assertTrue(reset.x >= layout.picture.x && reset.maxX <= layout.picture.maxX, screen.name)
            assertTrue(reset.y >= layout.picture.y && reset.maxY <= layout.picture.maxY, screen.name)
            val unlock = layout.aeUnlock(motionCluster = false)
            assertTrue(unlock.x >= layout.picture.x && unlock.maxX <= layout.picture.maxX, screen.name)
        }
    }

    /** A picture wider than 16:9 is not shrunk into the frame: it still spans the usable width. */
    @Test
    fun widerPictureKeepsTheFullWidth() {
        assertEquals(1210f, iPad11.layout(2.39f).picture.width)
        val phone = iPhone.layout(2.39f)
        assertEquals(48f, phone.picture.x)
        assertEquals(778f, phone.picture.width)
    }

    /**
     * Portrait has room above and below the picture, so a still keeps the full width there
     * (taller than a video picture, centred between the status row and the camera values).
     */
    @Test
    fun portraitStillKeepsTheFullWidth() {
        for ((width, height) in listOf(834f to 1210f, 402f to 874f)) {
            val layout = MonitorLayoutPolicy.fieldMonitor(
                width, height, safeTop = 24f, safeBottom = 20f, sourceAspect = 3f / 2f,
            )
            assertEquals(width, layout.picture.width, "$width")
            near(width / 1.5f, layout.picture.height, "$width")
        }
    }
}
