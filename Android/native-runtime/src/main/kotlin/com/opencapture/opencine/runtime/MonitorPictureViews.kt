package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Build
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup

/** Native window attachment. Covers keep this view attached and preserve the decode owner. */
class MonitorSurfacePictureHost(
    context: Context,
    private val attach: (Surface, Int, Int) -> Unit,
    private val detach: () -> Unit,
    private val journal: (String) -> Unit = {},
) : SurfaceView(context) {
    init {
        isClickable = false
        isFocusable = false
        setZOrderMediaOverlay(false)
        if (Build.VERSION.SDK_INT >= 34) {
            setSurfaceLifecycle(SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)
        }
        keepPicturePointersTogether()
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                journal("feed: surface created")
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                keepPicturePointersTogether()
                journal("feed: surface changed ${width}x${height}")
                attach(holder.surface, width, height)
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                journal("feed: surface destroyed")
                detach()
            }
        })
    }
}

/** The texture's native program, without a camera session or Compose dependency. */
interface MonitorTexturePictureProgram {
    fun attach(texture: SurfaceTexture, width: Int, height: Int)
    fun resize(width: Int, height: Int)
    fun detach()
}

/** Stable TextureView ownership for GLES and direct decoded-picture programs. */
class MonitorTexturePictureHost(
    context: Context,
    private val program: MonitorTexturePictureProgram,
    private val updated: (TextureView) -> Unit = {},
    private val journal: (String) -> Unit = {},
) : TextureView(context) {
    private var attachedTexture: SurfaceTexture? = null
    init {
        isOpaque = true
        surfaceTextureListener = object : SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
                if (attachedTexture != null) program.detach()
                attachedTexture = texture
                journal("feed: gles surface available ${width}x${height}")
                program.attach(texture, width, height)
            }
            override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {
                if (attachedTexture === texture) program.resize(width, height)
            }
            override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                // A late old-window callback must not tear down its replacement.
                if (attachedTexture !== texture) return true
                attachedTexture = null
                journal("feed: gles surface destroyed")
                program.detach()
                return true
            }
            override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {
                if (attachedTexture === texture) updated(this@MonitorTexturePictureHost)
            }
        }
    }
}

/** Direct MediaCodec output surface; release belongs to the native texture lifetime. */
class MonitorDecoderTextureProgram(private val decoderSurface: (Surface) -> Unit) : MonitorTexturePictureProgram {
    private var surface: Surface? = null
    override fun attach(texture: SurfaceTexture, width: Int, height: Int) {
        val next = Surface(texture)
        surface?.release()
        surface = next
        decoderSurface(next)
    }
    override fun resize(width: Int, height: Int) = Unit
    override fun detach() { surface?.release(); surface = null }
}

/** Keep both pinch fingers on one native view through its existing parent chain. */
fun View.keepPicturePointersTogether() {
    var walk: View? = this
    while (walk != null) {
        (walk as? ViewGroup)?.isMotionEventSplittingEnabled = false
        walk = walk.parent as? View
    }
}
