package com.opencapture.opencine.dji

import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import kotlin.test.Test
import kotlin.test.assertEquals
import org.json.JSONObject

class MulticamSupportTest {
    @Test
    fun incompleteNativeSupportNeverApprovesAnExperimentalRequest() {
        for (json in listOf(
            null,
            JSONObject(),
            JSONObject().put("appears", true).put("preview", true),
            JSONObject().put("appears", true).put("preview", "true").put("missingRoleQueryE0", false),
        )) {
            assertEquals(MulticamQualification.Unknown, MulticamSupportInfo.decode(json).qualification(experimental = true))
        }
        val complete = JSONObject().put("appears", true).put("preview", true).put("missingRoleQueryE0", false)
        assertEquals(MulticamQualification.Qualified, MulticamSupportInfo.decode(complete).qualification())
    }

    /** Swift `qualificationPreservesCapturedPreviewAndExperimentalPolicy`. */
    @Test
    fun qualificationPreservesCapturedPreviewAndExperimentalPolicy() {
        val unknown = MulticamSupportInfo(false, false, false, known = false)
        assertEquals(MulticamQualification.Unknown, unknown.qualification())
        assertEquals(MulticamQualification.Unknown, unknown.qualification(experimental = true))
        val captured = MulticamSupportInfo(true, true, true)
        assertEquals(MulticamQualification.Qualified, captured.qualification())
        val experimental = MulticamSupportInfo(true, false, false)
        val refused = MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
        assertEquals(refused, experimental.qualification())
        assertEquals(MulticamQualification.Qualified, experimental.qualification(experimental = true))
        assertEquals(refused, MulticamSupportInfo(false, false, false).qualification(experimental = true))
    }
}
