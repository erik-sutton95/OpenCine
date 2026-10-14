package com.opencapture.opencine.media

/** Stable named-curve input across a native boundary. Camera bytes stay with their integration. */
public object MonitorTransferWire {
    public fun tag(transfer: MonitorTransfer): String = when (transfer) {
        MonitorTransfer.REC709 -> "rec709"
        MonitorTransfer.HDR -> "hdr"
        MonitorTransfer.DLOG -> "dlog"
        MonitorTransfer.DLOG2 -> "dlog2"
        MonitorTransfer.DLOGM -> "dlogm"
        MonitorTransfer.ILOG -> "ilog"
        MonitorTransfer.SRGB -> "srgb"
        MonitorTransfer.NLOG -> "nlog"
        MonitorTransfer.LOG3G10 -> "log3G10"
    }

    /** An absent or unsupported name stays unknown, including an unclassified camera HDR mode. */
    public fun transfer(name: String?): MonitorTransfer? =
        MonitorTransfer.entries.firstOrNull { name != null && tag(it) == name }
}
