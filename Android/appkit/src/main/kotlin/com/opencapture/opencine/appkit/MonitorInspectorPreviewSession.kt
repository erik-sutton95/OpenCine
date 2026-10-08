package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.FeedEffectsRenderPlan
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One borrowed native preview subscription; implementations keep their existing worker. */
public interface MonitorInspectorPreviewClient<Picture> {
    public fun open(owner: Any, playback: Boolean, plan: FeedEffectsRenderPlan, receive: (Picture?) -> Unit)
    public fun update(owner: Any, plan: FeedEffectsRenderPlan)
    public fun close(owner: Any)
}

/**
 * Visible inspector lifetime. All calls and deliveries use the presentation thread.
 * Android's existing producer drives images; this owner adds no polling or native admission.
 */
public class MonitorInspectorPreviewSession<Picture>(private val client: MonitorInspectorPreviewClient<Picture>) {
    private val retainedImage: MutableStateFlow<Picture?> = MutableStateFlow(null)
    public val image: StateFlow<Picture?> = retainedImage.asStateFlow()
    private var active: Any? = null
    private var request: Any? = null

    public fun isCurrent(owner: Any): Boolean = active === owner

    public fun activate(playback: Boolean, plan: FeedEffectsRenderPlan): Any {
        val owner = Any()
        request = owner
        val previous = active
        active = null
        retainedImage.value = null
        if (previous != null) client.close(previous)
        // Closing or clearing the old picture can synchronously mount a successor.
        if (request !== owner) return owner
        active = owner
        client.open(owner, playback, plan) { picture ->
            if (isCurrent(owner)) retainedImage.value = picture
        }
        return owner
    }

    public fun update(plan: FeedEffectsRenderPlan) {
        val owner = active ?: return
        client.update(owner, plan)
    }

    public fun deactivate(owner: Any) {
        if (!isCurrent(owner)) return
        active = null
        request = null
        retainedImage.value = null
        // The native port receives only this captured owner, never a successor.
        client.close(owner)
    }
}
