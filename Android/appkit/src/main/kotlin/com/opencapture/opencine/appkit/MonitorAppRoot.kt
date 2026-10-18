package com.opencapture.opencine.appkit

import android.graphics.Color as AndroidColor
import android.os.Build
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.InfiniteAnimationPolicy
import androidx.compose.ui.platform.compositionContext
import androidx.compose.ui.platform.createLifecycleAwareWindowRecomposer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStoreOwner
import com.opencapture.opencine.appkit.diagnostics.AutomaticReportsPrompt
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReporting
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingConsent
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay

/**
 * The `android:configChanges` every monitor activity declares, so a resize in split screen, an
 * unfold, dark mode, display size, font scale or a game controller never recreates the activity
 * and drops the live session. The manifest attribute takes literal flags only: each app declares
 * these and its unit test checks the manifest with [missingIn].
 */
public object MonitorActivityConfigChanges {
    public val REQUIRED: List<String> = listOf(
        "orientation", "screenSize", "screenLayout", "smallestScreenSize", "keyboard", "keyboardHidden",
        "navigation", "uiMode", "density", "fontScale",
    )

    /**
     * The [REQUIRED] flags the `<activity>` named [activity] in [manifest] does not declare, or `null`
     * when the manifest has no such activity.
     */
    public fun missingIn(manifest: String, activity: String): List<String>? {
        val element = Regex("""<activity\b[^>]*>""").findAll(manifest).map { it.value }
            .firstOrNull { Regex("""android:name="\Q$activity\E"""").containsMatchIn(it) } ?: return null
        val declared = Regex("""android:configChanges="([^"]*)"""").find(element)?.groupValues?.get(1).orEmpty()
            .split('|').map(String::trim).toSet()
        return REQUIRED.filterNot(declared::contains)
    }
}

/**
 * The activity's one root owner (session, cameras, controllers): created once, kept when the
 * activity is recreated, closed only when the activity finishes for good.
 */
public fun <T : AutoCloseable> ViewModelStoreOwner.retainedMonitorRoot(create: () -> T): T {
    val holder = ViewModelProvider(this, RetainedMonitorRoot.Factory)[RetainedMonitorRoot::class.java]
    @Suppress("UNCHECKED_CAST")
    return (holder.root ?: create().also { holder.root = it }) as T
}

internal class RetainedMonitorRoot : ViewModel() {
    var root: AutoCloseable? = null

    override fun onCleared() {
        root?.close()
        root = null
    }

    object Factory : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <V : ViewModel> create(modelClass: Class<V>): V = RetainedMonitorRoot() as V
    }
}

/**
 * Launch plumbing every monitor activity shares. Hold the system splash until the first Compose
 * frame (`installSplashScreen().setKeepOnScreenCondition { !launch.firstFrameDrawn }` before
 * `super.onCreate`), then call [setContent].
 */
public class MonitorActivityLaunch {
    private val drawn = AtomicBoolean(false)

    /** The first Compose frame drew; the only branded splash from then on is [MonitorAppRoot]'s. */
    public val firstFrameDrawn: Boolean get() = drawn.get()

    /**
     * Edge to edge with dark transparent bars and the picture under the display cutout, then
     * [content] on a window recomposer whose infinite frame loops tick at about 30 Hz: Compose
     * `Popup` polls its anchor with an infinite loop, so an always-mounted popup alone woke Main
     * every vsync over live view (the iOS 30 Hz pulse timeline). Finite animations are untouched.
     */
    public fun setContent(activity: ComponentActivity, content: @Composable () -> Unit) {
        activity.enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        val window = activity.window
        window.isNavigationBarContrastEnforced = false
        window.attributes.layoutInDisplayCutoutMode =
            if (Build.VERSION.SDK_INT >= 35) WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        val recomposer = window.decorView.createLifecycleAwareWindowRecomposer(PacedInfiniteAnimations, activity.lifecycle)
        // The window's recomposer, so every composition in it (not only this content) is paced.
        window.decorView.compositionContext = recomposer
        activity.setContent(parent = recomposer) {
            SideEffect { drawn.set(true) }
            content()
        }
    }
}

/** Infinite frame loops tick at about 30 Hz instead of every vsync; finite animations are untouched. */
internal object PacedInfiniteAnimations : InfiniteAnimationPolicy {
    override suspend fun <R> onInfiniteOperation(block: suspend () -> R): R {
        delay(25)
        return block()
    }
}

/** The app's launch splash: its logo and wordmark over the same backdrop as its system splash. */
public class MonitorLaunchBrand(
    @param:DrawableRes public val logo: Int,
    public val wordmark: String,
    public val background: Color,
    public val ink: Color,
    /** `null`: the platform font. */
    public val wordmarkFont: FontFamily? = null,
    public val logoScale: ContentScale = ContentScale.Fit,
)

/** The automatic reports offer: the shared prompt over the app's reporting owners. */
public class MonitorReportsOffer(
    public val consent: ReliabilityReportingConsent,
    public val reporting: ReliabilityReporting,
    public val product: String,
    public val onPrivacy: () -> Unit,
)

/**
 * The root a monitor app composes around its shell (iOS app scene): the launch splash, keep-awake,
 * the screen-recording signal an HDR boost dims for, and the automatic reports offer, which waits
 * for the splash and for [reportsAllowed] (nothing the app shows over its home). An app whose
 * gating lives deeper composes the same parts itself.
 */
@Composable
public fun MonitorAppRoot(
    brand: MonitorLaunchBrand,
    keepScreenAwake: Boolean,
    reports: MonitorReportsOffer?,
    reportsAllowed: Boolean,
    splash: MonitorLaunchSplashState = rememberMonitorLaunchSplash(),
    onScreenRecording: ((Boolean) -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    MonitorKeepScreenAwake(keepScreenAwake)
    onScreenRecording?.let { MonitorScreenRecording(it) }
    Box(Modifier.fillMaxSize()) {
        content()
        MonitorLaunchSplash(brand, splash)
        if (!splash.visible && reportsAllowed && reports != null) MonitorAutomaticReportsOffer(reports)
    }
}

/** iOS `LaunchSplashTiming`. */
public object MonitorLaunchTiming {
    public const val VISIBLE_MILLIS: Long = 2_250
    public const val FADE_MILLIS: Int = 350
}

/** Whether the launch splash still shows. */
public class MonitorLaunchSplashState internal constructor(visible: Boolean) {
    public var visible: Boolean by mutableStateOf(visible)
        internal set
}

/**
 * The launch splash, once per launch: [MonitorLaunchTiming], and a recreated activity never shows
 * it again. [enabled] false skips it (debug and scripted launches).
 */
@Composable
public fun rememberMonitorLaunchSplash(enabled: Boolean = true): MonitorLaunchSplashState {
    var shown by rememberSaveable { mutableStateOf(!enabled) }
    val state = remember { MonitorLaunchSplashState(!shown) }
    LaunchedEffect(state) {
        if (state.visible) awaitMonitorLaunch()
        state.visible = false
        shown = true
    }
    return state
}

/** Keeps the screen on while the preference is enabled and this activity is active. */
@Composable
public fun MonitorKeepScreenAwake(enabled: Boolean) {
    val activity = LocalActivity.current ?: return
    val lifecycle = (activity as? LifecycleOwner)?.lifecycle ?: return
    val window = activity.window
    val currentEnabled by rememberUpdatedState(enabled)
    val owner = remember(window) {
        MonitorScreenWakeOwner { keepAwake ->
            if (keepAwake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    SideEffect {
        owner.update(enabled, lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    DisposableEffect(lifecycle, owner) {
        val observer = LifecycleEventObserver { _, _ ->
            owner.update(currentEnabled, lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        }
        lifecycle.addObserver(observer)
        owner.update(currentEnabled, lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        onDispose {
            lifecycle.removeObserver(observer)
            owner.retire()
        }
    }
}

/** Reports whether the screen is being recorded (API 35+); a ROM that refuses the callback costs only the signal. */
@Composable
public fun MonitorScreenRecording(onChange: (Boolean) -> Unit) {
    val activity = LocalActivity.current
    val current by rememberUpdatedState(onChange)
    DisposableEffect(activity) {
        val windowManager = activity?.windowManager
        if (activity == null || windowManager == null || Build.VERSION.SDK_INT < 35) return@DisposableEffect onDispose { }
        val callback = java.util.function.Consumer<Int> { state ->
            current(state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE)
        }
        try {
            windowManager.addScreenRecordingCallback(activity.mainExecutor, callback)
        } catch (_: SecurityException) {
            return@DisposableEffect onDispose { }
        }
        onDispose { runCatching { windowManager.removeScreenRecordingCallback(callback) } }
    }
}

/** The automatic reports prompt until the operator answers it once. */
@Composable
public fun MonitorAutomaticReportsOffer(offer: MonitorReportsOffer) {
    var open by remember(offer.consent) { mutableStateOf(offer.consent.shouldOfferAutomaticPrompt()) }
    if (!open) return
    AutomaticReportsPrompt(
        product = offer.product,
        onPrivacy = offer.onPrivacy,
        onEnable = { offer.reporting.setConsent(true); open = false },
        onNotNow = { offer.reporting.setConsent(false); open = false },
    )
}

/** Solid backdrop, the app logo with continuous corners (size x 0.22) and the wordmark (iOS `LaunchSplashContent`). */
@Composable
public fun MonitorLaunchSplash(brand: MonitorLaunchBrand, state: MonitorLaunchSplashState) {
    AnimatedVisibility(visible = state.visible, enter = EnterTransition.None, exit = fadeOut(tween(MonitorLaunchTiming.FADE_MILLIS))) {
        BoxWithConstraints(Modifier.fillMaxSize().background(brand.background).testTag(MONITOR_LAUNCH_SPLASH_TAG)) {
            val landscape = maxWidth >= maxHeight
            val logoSize = minOf(maxWidth * if (landscape) 0.16f else 0.28f, 96.dp)
            val wordmarkSize = if (landscape) 34.sp else 30.sp
            val mark: @Composable () -> Unit = {
                Image(painterResource(brand.logo), contentDescription = brand.wordmark, contentScale = brand.logoScale,
                    modifier = Modifier.size(logoSize).clip(RoundedCornerShape(logoSize * 0.22f)))
                Text(brand.wordmark, color = brand.ink, fontSize = wordmarkSize, fontWeight = FontWeight.Bold,
                    fontFamily = brand.wordmarkFont)
            }
            if (landscape) {
                Row(Modifier.fillMaxSize().padding(horizontal = max(32.dp, maxWidth * 0.08f)),
                    horizontalArrangement = Arrangement.spacedBy(max(32.dp, maxWidth * 0.06f), Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically) { mark() }
            } else {
                Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically)) { mark() }
            }
        }
    }
}

/** The launch splash's test tag. */
public const val MONITOR_LAUNCH_SPLASH_TAG: String = "monitor-launch-splash"

/** The integration's answer to "may discovery restart while a camera connects or is live?". */
public enum class DiscoveryRestart {
    /** A new scan leaves the attempt alone (the integration ignores a scan while it connects). */
    ANY_TIME,

    /** A new scan clears the integration's reconnect state, so it starts only while nothing connects or is live. */
    WHEN_IDLE;

    public fun allows(cameras: CamerasModel.State, live: Boolean): Boolean =
        this == ANY_TIME || (cameras.attempts.isEmpty() && cameras.connected == null && !live)
}
