package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** SIMULATED operator actions. No transport or camera command is involved. */
class OperatorConsentTest {
    @Test fun aConfirmationIsConsumedBeforeCallingTheHost() {
        val owner = OperatorConsent()
        var admitted = 0
        val request = OperatorConsentRequest("Use camera?", "Another operator loses their session.", "Continue", onConfirm = { admitted++ })
        owner.present(request, "source-1")
        owner.confirm(request.id)
        owner.confirm(request.id)
        owner.present(request, "source-1")
        owner.confirm(request.id)
        assertEquals(1, admitted)
        assertNull(owner.pending.value)
    }

    @Test fun cancellingNeverAdmitsAndOnlyCancelsOnce() {
        val owner = OperatorConsent()
        var admitted = 0
        var cancelled = 0
        val request = OperatorConsentRequest("Use camera?", "Consent required", "Continue", onConfirm = { admitted++ }, onCancel = { cancelled++ })
        owner.present(request, "source-1")
        owner.cancel(request.id)
        owner.confirm(request.id)
        owner.cancel(request.id)
        assertEquals(0, admitted)
        assertEquals(1, cancelled)
    }

    @Test fun aSupersededAlertCannotConfirmOrDismissItsSuccessor() {
        val owner = OperatorConsent()
        val actions = mutableListOf<String>()
        val first = OperatorConsentRequest("First", "First source", "Continue", onConfirm = { actions += "first" }, onCancel = { actions += "cancel-first" })
        val second = OperatorConsentRequest("Second", "Second source", "Continue", onConfirm = { actions += "second" }, onCancel = { actions += "cancel-second" })
        owner.present(first, "source-1")
        owner.present(second, "source-2")
        owner.confirm(first.id)
        owner.cancel(first.id)
        assertEquals(second.id, owner.pending.value?.id)
        assertEquals(emptyList(), actions)
        owner.confirm(second.id)
        assertEquals(listOf("second"), actions)
    }

    @Test fun retirementSendsNoCommandAndRejectsLateConfirmation() {
        val owner = OperatorConsent()
        var actions = 0
        val request = OperatorConsentRequest("Use camera?", "Consent required", "Continue", onConfirm = { actions++ }, onCancel = { actions++ })
        owner.present(request, "source-1")
        owner.retire("unrelated")
        assertEquals(request.id, owner.pending.value?.id)
        owner.retire("source-1")
        owner.confirm(request.id)
        assertNull(owner.pending.value)
        assertEquals(0, actions)
    }

    @Test fun aSourceThatRetiredBeforeItsDismissalCannotBeAdmitted() {
        val owner = OperatorConsent()
        var current = true
        var actions = 0
        val request = OperatorConsentRequest("Use camera?", "Consent required", "Continue", onConfirm = { actions++ }, onCancel = { actions++ })
        owner.present(request, "source-1", isCurrent = { current })
        current = false
        owner.confirm(request.id)
        assertNull(owner.pending.value)
        assertEquals(0, actions)
    }
}
