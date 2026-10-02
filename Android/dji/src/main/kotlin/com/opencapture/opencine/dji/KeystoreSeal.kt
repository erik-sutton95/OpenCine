package com.opencapture.opencine.dji

/** Compatibility path. Storage format and alias are owned by the caller. */
class KeystoreSeal(alias: String) {
    private val delegate = com.opencapture.opencine.platform.KeystoreSeal(alias)
    fun seal(secret: String): String? = delegate.seal(secret)
    fun open(stored: String): String? = delegate.open(stored)

    companion object {
        const val SEPARATOR = com.opencapture.opencine.platform.KeystoreSeal.SEPARATOR
    }
}
