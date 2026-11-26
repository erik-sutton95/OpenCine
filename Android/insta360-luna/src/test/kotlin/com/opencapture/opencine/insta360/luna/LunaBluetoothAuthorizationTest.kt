package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The model gate of the Bluetooth authorization: a Luna Ultra or Luna Pro goes on to the key
 * exchange; any other Insta360 camera on the shared BE80 service is refused by name before anything
 * else is sent. Swift mirror: `LunaBluetoothAuthorizationTests`, same method names.
 */
class LunaBluetoothAuthorizationTest {
    /** A camera behind the Bluetooth link that reports [model] and approves this phone. */
    private class Camera(val model: String) {
        val sent = mutableListOf<Int>()
        val identified = mutableListOf<LunaModel>()
        private val key = LunaWire.keyPair()

        fun authorization() = LunaBluetoothAuthorization(
            request = { code, body, _ -> answer(code, body) }, agreed = {},
            approvals = { LunaWire.Message(8209, 1, LunaWire.integer(1, 0) + LunaWire.integer(2, 0), false) },
            identified = { model, _ -> identified += model },
            appName = "OpenInstaCine",
        )

        private fun answer(code: Int, body: ByteArray): ByteArray {
            sent += code
            return when (code) {
                8 -> if (body.contentEquals(LunaWire.options(36, 37, 43))) ByteArray(0) else LunaWire.blob(
                    2, LunaWire.blob(48, model.toByteArray()) + LunaWire.blob(15, "SN-LUNA".toByteArray()) + LunaWire.blob(30, "1.2.7".toByteArray()),
                )
                240 -> LunaWire.integer(1, 3)
                241 -> LunaWire.integer(1, 1) + LunaWire.blob(2, LunaWire.publicBytes(key))
                39 -> LunaWire.integer(1, 0)
                else -> ByteArray(0)
            }
        }
    }

    @Test fun aLunaUltraOrLunaProIsAuthorized() = runTest {
        for (model in LunaModel.supported) {
            val camera = Camera(model.reportedName)
            val (serial, _) = camera.authorization().run(byteArrayOf(1))
            assertEquals("SN-LUNA", serial)
            assertEquals(listOf(model), camera.identified)
            assertTrue(241 in camera.sent && 39 in camera.sent)
        }
    }

    @Test fun anotherInsta360CameraIsRefusedByName() = runTest {
        for ((model, message) in listOf(
            "Insta360 ONE RS" to "This camera is Insta360 ONE RS. OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.",
            "Insta360 Luna Max" to "This camera is Insta360 Luna Max, a Luna model OpenInstaCine does not support yet. " +
                "OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.",
        )) {
            val camera = Camera(model)
            val refused = assertFailsWith<LunaUnsupportedCamera> { camera.authorization().run(byteArrayOf(1)) }
            val failure = refused.failure
            assertEquals(ConnectionFailure.Reason.Unsupported, failure?.reason)
            assertEquals("com.opencapture.insta360.luna.model.unsupported", failure?.code)
            assertEquals(message, failure?.message)
            assertEquals(listOf(8), camera.sent, "nothing past the identity read reaches $model")
            assertTrue(camera.identified.isEmpty())
        }
    }
}
