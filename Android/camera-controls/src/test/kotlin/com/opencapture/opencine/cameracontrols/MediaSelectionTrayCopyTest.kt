package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals

class MediaSelectionTrayCopyTest {
    @Test fun selectionActionsNameTheCountAndTheCameraCard() {
        assertEquals("Delete 3 selected items from the camera card", selectionDeleteDescription(3, true))
        assertEquals("Delete 1 selected item from the camera card", selectionDeleteDescription(1, true))
        assertEquals("Delete selected media", selectionDeleteDescription(2, false))
        assertEquals("Share 3 selected items", selectionShareDescription(3))
        assertEquals("Share 1 selected item", selectionShareDescription(1))
    }
}
