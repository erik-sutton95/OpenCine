package com.opencapture.opencine.vocabulary

/**
 * Operator-visible stage of a DJI connection: BLE, then Wi-Fi, then datalink. Mirrors Swift
 * `ConnectionPhase` in OpenPocketViewCore. Commands and camera state use OpenCineCore
 * (`com.opencapture.opencine.core`), not this enum.
 */
enum class ConnectionPhase {
    IDLE,
    SCANNING,
    CONNECTING_GATT,
    PAIRING,
    AWAITING_APPROVAL,
    READING_WIFI_CREDS,
    JOINING_WIFI,
    OPENING_DATALINK,
    LIVE,
    FAILED,
}
