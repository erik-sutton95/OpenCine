package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ExposureCompensationTest {
    @Test fun thirdsRoundTripAcrossOperatorRangeWithoutWireOffset() {
        val range = -9..9
        for (thirds in range) assertEquals(thirds, ExposureCompensation.fromLabel(ExposureCompensation.label(thirds), range))
        assertEquals("+0.3", ExposureCompensation.label(1))
        assertEquals("\u22122.7", ExposureCompensation.label(-8))
        assertEquals(-1, ExposureCompensation.fromLabel("-0.3", range))
    }

    @Test fun overflowCannotTurnLargeLabelsIntoSupportedOffsets() {
        for (label in listOf("+1431655766.0", "-1431655766.3", "+9223372036854775807.7", "-9223372036854775807.0")) {
            assertNull(ExposureCompensation.fromLabel(label, -9..9))
        }
        assertEquals("\u2212715827882.7", ExposureCompensation.label(Int.MIN_VALUE))
        assertEquals(Int.MIN_VALUE, ExposureCompensation.fromLabel("-715827882.7", Int.MIN_VALUE..Int.MAX_VALUE))
    }

    @Test fun supportedRangeAndInvalidFractionStayExplicit() {
        assertNull(ExposureCompensation.fromLabel("+0.5", -9..9))
        assertNull(ExposureCompensation.fromLabel("2.0", -9..9))
        assertNull(ExposureCompensation.fromLabel("+3.0", -6..6))
        assertNull(ExposureCompensation.fromLabel("-2.7", -6..9))
        assertEquals(9, ExposureCompensation.fromLabel("+3.0", -6..9))
    }
}
