package com.opencapture.opencine.appkit

/** Which of this phone's networks a Multiview stage watches. Swift twin: `MultiviewNetworkPath`. */
public enum class MultiviewNetworkPath {
    /**
     * The network the stage chose: this phone's hotspot when the hotspot source is picked, else
     * its Wi-Fi. A stage without a commissioner watches Wi-Fi. The default.
     */
    CHOSEN,

    /**
     * Whichever network this phone is on: its Wi-Fi when it has an address there, else the
     * hotspot it hosts. For a stage without a commissioner whose cameras may share the phone's
     * own hotspot.
     */
    EITHER,
}
