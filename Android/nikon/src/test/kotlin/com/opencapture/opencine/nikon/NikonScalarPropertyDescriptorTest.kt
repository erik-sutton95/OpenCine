package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NikonScalarPropertyDescriptorTest {
    // SIMULATED existing UINT8 movie focus property, not a candidate movie-tone identity.
    private val property = 0xD1FAL
    private val extended = byteArrayOf(0xFA.toByte(), 0xD1.toByte(), 0, 0, 2, 0, 1, 0, 2, 2, 3, 0, 0, 2, -1)

    @Test fun preservesReportedMetadataAndUnknownEnum() {
        val observed = assertNotNull(NikonScalarPropertyDescriptor.parse(extended, property, 1))
        assertTrue(observed.writable)
        assertEquals(listOf(0.toByte()), observed.defaultValue)
        assertEquals(listOf(2.toByte()), observed.currentValue)
        assertEquals(NikonScalarPropertyDescriptor.Form.Enumeration(listOf(listOf(0), listOf(2), listOf(-1)).map { values -> values.map(Int::toByte) }), observed.form)
        val readOnly = extended.copyOf().apply { this[6] = 0 }
        assertEquals(false, NikonScalarPropertyDescriptor.parse(readOnly, property, 1)?.writable)
    }

    @Test fun standardAndExtendedWidthsDoNotAcceptAnAlias() {
        val standard = extended.take(2).toByteArray() + extended.drop(4).toByteArray()
        assertNotNull(NikonScalarPropertyDescriptor.parse(standard, property, 1))
        assertNull(NikonScalarPropertyDescriptor.parse(standard, property or 0x10000, 1))
        assertNull(NikonScalarPropertyDescriptor.parse(extended, property + 1, 1))
    }

    @Test fun rejectsMalformedTruncatedAndTrailingDatasets() {
        for (count in extended.indices) {
            assertNull(NikonScalarPropertyDescriptor.parse(extended.copyOf(count), property, 1))
        }
        for (index in listOf(4, 6, 9)) {
            val malformed = extended.copyOf().apply { this[index] = 7 }
            assertNull(NikonScalarPropertyDescriptor.parse(malformed, property, 1))
        }
        assertNull(NikonScalarPropertyDescriptor.parse(extended + byteArrayOf(0), property, 1))
    }
}
