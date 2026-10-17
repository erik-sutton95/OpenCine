package com.opencapture.opencine.frameio

import android.util.Log
import java.security.MessageDigest

/**
 * JNI facade for the shared Frame.io wire: PKCE, exact redirect validation, Adobe IMS forms, V4
 * endpoint planning and Codable response decoding. The natives are implemented in Swift by
 * OpenCine's OpenCineFrameIOAndroid target, which an app's Swift Android library links and
 * exports as `Java_com_opencapture_opencine_frameio_FrameioNative_<name>`, so this class name,
 * package and member names are part of the native contract (consumer-rules.pro keeps them).
 * Returned JSON can carry verifiers, codes and tokens: never log it.
 *
 * The app calls [load] with its library name once, before any Frame.io call.
 */
object FrameioNative {
    /** True once [load] has loaded the library that implements these natives. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    /** Loads the app's JNI library ([library] without `lib` and `.so`); false when absent. */
    @Synchronized
    fun load(library: String): Boolean {
        if (isAvailable) return true
        isAvailable =
            try {
                System.loadLibrary(library)
                true
            } catch (e: UnsatisfiedLinkError) {
                // JVM unit tests have no `.so` to load and no `android.util.Log` to log with.
                runCatching { Log.e("FrameioNative", "lib$library.so did not load", e) }
                false
            }
        return isAvailable
    }

    /**
     * The platform SHA-256 Swift injects into PKCE (the injected digest contract): called back
     * by name from the [beginAuthorization] native on this thread. Not for other callers.
     */
    fun sha256(input: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(input)

    external fun beginAuthorization(clientID: String, redirectURI: String): String?

    external fun parseRedirect(redirectURI: String, callbackURI: String, expectedState: String): String?

    external fun tokenRequest(
        kind: String, clientID: String, redirectURI: String,
        code: String?, verifier: String?, refreshToken: String?,
    ): String?

    external fun apiRequest(
        operation: String, accountID: String?, workspaceID: String?,
        folderID: String?, fileID: String?, name: String?, fileSize: Long,
    ): String?

    external fun decodeResponse(operation: String, response: String): String?

    external fun mediaTypeForFilename(filename: String): String
}
