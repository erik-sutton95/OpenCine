package com.opencapture.opencine.core.testing

import java.util.Random

/**
 * Bounded local video loss on a supplied clock.
 * The apps' instrumented feed-stress tests share this fixture.
 */
public class FeedStressFault(seed: Long, private val nowMs: () -> Long) {
    private val random = Random(seed)
    private var expires = 0L
    private var offered = 0
    private var profile = "loss"

    @Volatile
    public var dropped: Long = 0L
        private set

    public fun arm(profile: String) {
        require(profile in PROFILES)
        this.profile = profile
        offered = 0
        expires = nowMs() + 8_000
    }

    public fun disarm() {
        expires = 0
    }

    public fun admit(): Boolean {
        if (nowMs() >= expires) return true
        offered += 1
        val drop = when (profile) {
            "loss" -> random.nextInt(100) < 10
            "burst" -> offered % 40 < 8
            "combined" -> offered % 40 < 8 || random.nextInt(100) < 10
            else -> false
        }
        if (drop) dropped += 1
        return !drop
    }

    public companion object {
        public val PROFILES: Set<String> = setOf("loss", "burst", "combined")
    }
}
