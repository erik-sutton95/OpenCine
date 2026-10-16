package com.opencapture.monitorui

import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.util.concurrent.CountDownLatch

/** Full-screen host for the instrumented tests: the window the apps' monitor runs in, no content. */
class MonitorTestActivity : ComponentActivity() {
    private var applied: Configuration? = null

    /** Released once the window's open transition has finished; until then the display may show it animating in. */
    val entered = CountDownLatch(1)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A relaunch drops the content a test set through onActivity; the manifest handles overlay
        // changes in place, and this line makes any other relaunch visible in the run's log.
        Log.i(TAG, "created $this restored=${savedInstanceState != null}")
        applied = Configuration(resources.configuration)
        enableEdgeToEdge()
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        val diff = applied?.diff(newConfig) ?: 0
        Log.i(TAG, "configuration changed in place on $this: 0x${Integer.toHexString(diff)}")
        applied = Configuration(newConfig)
        super.onConfigurationChanged(newConfig)
    }

    override fun onEnterAnimationComplete() {
        super.onEnterAnimationComplete()
        entered.countDown()
    }

    private companion object { const val TAG = "MonitorTestActivity" }
}
