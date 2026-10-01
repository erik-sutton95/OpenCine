package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DecoderRandomAccessHoldTest {
    @Test
    fun survivingDecoderWithReferencesReleasesHoldWithoutEnable() {
        val hold = DecoderRandomAccessHold()
        hold.onNewDecoder()
        hold.onIrapAccepted()
        assertFalse(hold.awaitingIdr)
        assertTrue(hold.hasDecodableReferences)
        hold.beginHold()
        assertTrue(hold.awaitingIdr)
        assertTrue(hold.shouldAccept(isIrap = true))
        assertFalse(hold.shouldAccept(isIrap = false))
        assertTrue(hold.endHold())
        assertFalse(hold.awaitingIdr)
        assertTrue(hold.shouldAccept(isIrap = false))
    }

    @Test
    fun newDecoderWithoutRandomAccessKeepsHold() {
        val hold = DecoderRandomAccessHold()
        hold.onNewDecoder()
        assertTrue(hold.awaitingIdr)
        assertFalse(hold.hasDecodableReferences)
        assertFalse(hold.endHold(), "releasing cannot recreate missing references")
        assertTrue(hold.awaitingIdr)
        assertFalse(hold.shouldAccept(isIrap = false))
        assertTrue(hold.shouldAccept(isIrap = true))
        hold.onIrapAccepted()
        assertTrue(hold.hasDecodableReferences)
        assertFalse(hold.awaitingIdr)
    }

    @Test
    fun incompleteAuDropsBreakReferencesAndKeepTheHeldImage() {
        val hold = DecoderRandomAccessHold()
        hold.onNewDecoder()
        hold.onIrapAccepted()
        assertTrue(AccessUnitDiscontinuity.shouldNote(0, 2))
        assertTrue(!AccessUnitDiscontinuity.shouldNote(2, 2))
        hold.noteBrokenReferences()
        assertFalse(hold.hasDecodableReferences)
        assertTrue(hold.awaitingIdr)
        assertFalse(hold.endHold())
        assertFalse(hold.shouldAccept(isIrap = false))
        hold.onIrapAccepted()
        assertTrue(hold.hasDecodableReferences)
    }
}
