package com.opencapture.opencine.streaming

import android.view.Surface
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** A virtual-time serial scheduler: tasks and timers run only when the test advances it. */
private class ManualScheduler : StreamScheduler {
    var nowNs = 0L
    private val ready = ArrayDeque<() -> Unit>()
    private class Timer(var dueNs: Long, val periodNs: Long?, val task: () -> Unit) { var cancelled = false }
    private val timers = mutableListOf<Timer>()
    var shutDown = false

    override fun execute(task: () -> Unit) { ready.addLast(task) }

    override fun schedule(delayNs: Long, task: () -> Unit): StreamScheduler.Cancellable =
        add(Timer(nowNs + delayNs.coerceAtLeast(0), null, task))

    override fun repeat(periodNs: Long, task: () -> Unit): StreamScheduler.Cancellable =
        add(Timer(nowNs, periodNs, task))

    override fun shutdown() { shutDown = true }

    private fun add(timer: Timer): StreamScheduler.Cancellable {
        timers += timer
        return StreamScheduler.Cancellable { timer.cancelled = true }
    }

    fun drain() { while (ready.isNotEmpty()) ready.removeFirst()() }

    /** Runs every task and timer due up to [targetNs], in time order. */
    fun advanceTo(targetNs: Long) {
        drain()
        while (true) {
            val next = timers.filter { !it.cancelled && it.dueNs <= targetNs }.minByOrNull { it.dueNs } ?: break
            nowNs = next.dueNs
            if (next.periodNs == null) { next.cancelled = true } else next.dueNs += next.periodNs
            next.task()
            drain()
        }
        nowNs = targetNs
        drain()
    }
}

private class FakeConnection(val host: String, val port: Int, val tls: Boolean) : StreamConnection {
    var onEvent: (StreamConnectionEvent) -> Unit = {}
    val writes = mutableListOf<ByteArray>()
    var closed = false
    override fun open(onEvent: (StreamConnectionEvent) -> Unit) { this.onEvent = onEvent }
    override fun write(bytes: ByteArray) { writes += bytes }
    override fun close() { closed = true }
}

private class FakeVideo : StreamVideoEncoder {
    /** android.jar's stub Surface: the publisher only hands it to the picture source. */
    override val inputSurface: Surface? = Surface(null as android.graphics.SurfaceTexture?)
    var output: (StreamMediaPacket) -> Unit = {}
    var keyframes = 0
    val bitrates = mutableListOf<Int>()
    var released = false
    override fun start(startNs: Long, output: (StreamMediaPacket) -> Unit) { this.output = output }
    override fun setBitrate(bps: Int) { bitrates += bps }
    override fun requestKeyframe() { keyframes += 1 }
    override fun release() { released = true }
}

private class FakePicture : StreamPictureSource {
    val draws = mutableListOf<Pair<Long, Boolean>>()
    var attached = false
    var detached = false
    var onPicture: () -> Unit = {}
    override fun attach(surface: Surface, width: Int, height: Int, crop: Boolean, onPicture: () -> Unit) {
        attached = true
        this.onPicture = onPicture
    }
    override fun draw(presentationTimeNs: Long, slate: Boolean) { draws += presentationTimeNs to slate }
    override fun detach() { detached = true }
}

class StreamPublisherTest {
    private val scheduler = ManualScheduler()
    private val native = FakeStreamingNative()
    private val connections = mutableListOf<FakeConnection>()
    private val video = FakeVideo()
    private val picture = FakePicture()
    private val format = StreamOutputFormat.fromJson(FakeStreamingNative.FORMAT_720P)!!

    private fun publisher(withPicture: Boolean = true) = StreamPublisher(
        native, format, "rtmps://live.example.com/app", "SECRETKEY", crop = false,
        picture = picture.takeIf { withPicture }, video = video, audio = null,
        connect = { host, port, tls -> FakeConnection(host, port, tls).also { connections += it } },
        clock = { scheduler.nowNs }, scheduler = scheduler,
    )

    /** Starts and opens the first connection; the fake engine goes live on connect. */
    private fun live(): StreamPublisher = publisher().also {
        it.start()
        scheduler.drain()
        connections.last().onEvent(StreamConnectionEvent.Opened)
        scheduler.drain()
    }

    @Test
    fun appliesActionsInOrder() {
        val stream = publisher()
        assertEquals(StreamDestinationCheck.Ok(encrypted = true), stream.start())
        scheduler.drain()
        val first = connections.single()
        assertEquals(Triple("live.example.com", 443, true), Triple(first.host, first.port, first.tls))
        assertEquals(StreamPhase.Connecting, stream.status.value.phase)
        first.onEvent(StreamConnectionEvent.Opened)
        scheduler.drain()
        assertContentEquals(FakeStreamingNative.HELLO, first.writes.single())
        assertEquals(1, video.keyframes)
        assertEquals(StreamPhase.Live, stream.status.value.phase)
        assertEquals(listOf("create", "start", "connected"), native.calls)
    }

    @Test
    fun badDestinationNeverConnects() {
        native.createError = "notRTMPS"
        val stream = publisher()
        assertEquals(StreamDestinationCheck.Invalid(StreamDestinationProblem.NOT_RTMPS), stream.start())
        scheduler.advanceTo(5_000_000_000)
        assertTrue(connections.isEmpty())
        assertIs<StreamPhase.Ended>(stream.status.value.phase)
    }

    @Test
    fun plainServerConnectsWithoutTls() {
        native.tls = false
        val stream = publisher()
        assertEquals(StreamDestinationCheck.Ok(encrypted = false), stream.start())
        scheduler.drain()
        assertEquals(false, connections.single().tls)
    }

    @Test
    fun framesWaitUntilLive() {
        val stream = publisher()
        stream.start()
        scheduler.advanceTo(200_000_000)
        assertTrue(picture.draws.isEmpty())
        connections.single().onEvent(StreamConnectionEvent.Opened)
        scheduler.drain()
        picture.onPicture()
        scheduler.advanceTo(1_200_000_000)
        assertTrue(picture.draws.size in 29..31, "draws: ${picture.draws.size}")
        assertTrue(picture.draws.none { it.second })
    }

    @Test
    fun lostSourceDrawsTheSlate() {
        live()
        picture.onPicture()
        scheduler.drain()
        scheduler.advanceTo(3_000_000_000)
        assertTrue(picture.draws.filter { it.first < 1_990_000_000L }.none { it.second })
        assertTrue(picture.draws.filter { it.first >= 2_000_000_000L }.all { it.second })
        assertEquals(true, picture.draws.last().second)
    }

    @Test
    fun mediaReachesTheRunAndTheSocket() {
        live()
        video.output(StreamMediaPacket.Video(byteArrayOf(0, 0, 1, 0x65, 7), true, 0, 0))
        scheduler.drain()
        assertContentEquals(byteArrayOf(0, 0, 1, 0x65, 7), connections.single().writes.last())
    }

    @Test
    fun lostConnectionWaitsToReconnect() {
        val stream = live()
        val first = connections.single()
        first.onEvent(StreamConnectionEvent.Lost)
        scheduler.drain()
        assertEquals(StreamPhase.Reconnecting(1), stream.status.value.phase)
        video.output(StreamMediaPacket.Video(byteArrayOf(0, 0, 1, 0x41), false, 40, 40))
        scheduler.advanceTo(999_000_000)
        assertEquals(1, connections.size)
        assertEquals(1, first.writes.size)
        scheduler.advanceTo(1_000_000_000)
        assertEquals(2, connections.size)
        connections.last().onEvent(StreamConnectionEvent.Opened)
        scheduler.drain()
        assertEquals(StreamPhase.Live, stream.status.value.phase)
        assertEquals(2, video.keyframes)
    }

    @Test
    fun staleConnectionEventsAreIgnored() {
        live()
        val first = connections.single()
        first.onEvent(StreamConnectionEvent.Lost)
        scheduler.advanceTo(1_000_000_000)
        val callsBefore = native.calls.size
        first.onEvent(StreamConnectionEvent.Received(byteArrayOf(1)))
        first.onEvent(StreamConnectionEvent.Lost)
        scheduler.drain()
        assertEquals(callsBefore, native.calls.size)
    }

    @Test
    fun keyframeAndBitrateReachTheEncoder() {
        live()
        assertEquals(1, video.keyframes)
        native.videoBitrateBps = 2_250_000
        val reply = FakeStreamingNative.encodeReply(
            listOf(StreamAction.SetVideoBitrate(2_250_000), StreamAction.RequestKeyframe),
            StreamStatus(StreamPhase.Live, 0, 0, 2_250_000, 0, 0, StreamHealth.CONGESTED),
        )
        val scripted = object : StreamingNativeApi by native {
            override fun tick(owner: String, nowNs: Long): ByteArray = reply
        }
        val stream = StreamPublisher(
            scripted, format, "rtmps://live.example.com/app", "k", false, null, video, null,
            connect = { h, p, t -> FakeConnection(h, p, t).also { connections += it } },
            clock = { scheduler.nowNs }, scheduler = scheduler,
        )
        stream.start()
        scheduler.advanceTo(scheduler.nowNs + 1_000_000_000)
        assertEquals(2_250_000, video.bitrates.last())
        assertTrue(video.keyframes >= 2)
        assertEquals(StreamHealth.CONGESTED, stream.status.value.health)
    }

    @Test
    fun stopEndsTheRun() {
        val stream = live()
        val first = connections.single()
        stream.stop()
        scheduler.drain()
        assertContentEquals(FakeStreamingNative.GOODBYE, first.writes.last())
        assertTrue(first.closed)
        assertEquals(StreamPhase.Ended(StreamEnd.Stopped), stream.status.value.phase)
        assertTrue(video.released && picture.detached && scheduler.shutDown)
        assertEquals("close", native.calls.last())
        val draws = picture.draws.size
        scheduler.advanceTo(5_000_000_000)
        assertEquals(draws, picture.draws.size)
        stream.stop()
        scheduler.drain()
    }

    @Test
    fun refusalEndsWithTheReason() {
        native.refuseWith = "Wrong stream key"
        val stream = publisher()
        stream.start()
        scheduler.drain()
        connections.single().onEvent(StreamConnectionEvent.Opened)
        scheduler.drain()
        assertEquals(StreamPhase.Ended(StreamEnd.Refused("Wrong stream key")), stream.status.value.phase)
        scheduler.advanceTo(10_000_000_000)
        assertEquals(1, connections.size)
    }
}
