import OpenCineDJI
import Testing

/// Twin of Kotlin `MultiviewExitTest`.
@Suite struct MultiviewExitTests {
    private func reply(_ payload: [UInt8], opcode: UInt8 = 0x45) -> Duml.Frame {
        Duml.Frame(sender: 7, receiver: 2, seq: 1202, flags: 0x80, cmdSet: 7, cmdId: opcode, payload: payload)
    }

    @Test func firstExitRetriesCapturedReplyAfterClosingTheAttempt() async {
        var attempts = 0
        var closes = 0
        var waits = 0
        var apCommands = 0
        let restored = await restoreCameraWiFiWithRetry(waitBetween: {
            waits += 1
            #expect(attempts == closes)
        }) {
            attempts += 1
            defer { closes += 1 }
            guard try MultiviewPairing.acceptsReply(reply(attempts == 1 ? [0, 6] : [0, 1]), sequence: 1202)
            else { return false }
            apCommands += 1
            return true
        }
        #expect(restored)
        #expect(attempts == 2)
        #expect(waits == 1)
        #expect(apCommands == 1)
        #expect(closes == 2)
    }

    @Test func repeatedDeferralStopsAtThreeAttempts() async {
        var attempts = 0
        let restored = await restoreCameraWiFiWithRetry(waitBetween: {}) {
            attempts += 1
            return try MultiviewPairing.acceptsReply(reply([0, 6]), sequence: 1202)
        }
        #expect(!restored)
        #expect(attempts == 3)
    }

    @Test func otherRejectionsAndFailedAPCommandsDoNotRetry() async {
        for pairingRejected in [true, false] {
            var attempts = 0
            let restored = await restoreCameraWiFiWithRetry(waitBetween: {
                Issue.record("Unexpected retry")
            }) {
                attempts += 1
                if pairingRejected { _ = try MultiviewPairing.acceptsReply(reply([0, 3]), sequence: 1202) }
                return false
            }
            #expect(!restored)
            #expect(attempts == 1)
        }
    }

    @Test func approvalRequiresMatchingOpcodeSequenceAndExactReply() throws {
        #expect(try MultiviewPairing.acceptsReply(reply([0, 1]), sequence: 1202))
        #expect(try !MultiviewPairing.acceptsReply(reply([0, 1]), sequence: 1203))
        #expect(try !MultiviewPairing.acceptsReply(reply([0, 1], opcode: 0x39), sequence: 1202))
        #expect(try !MultiviewPairing.acceptsReply(reply([0, 2]), sequence: 1202))
        #expect(throws: MultiviewFailure.rejected) {
            try MultiviewPairing.acceptsReply(reply([0, 3]), sequence: 1202)
        }
    }

    @Test func cancellationDoesNotBecomeAReportedSuccess() async {
        var attempts = 0
        let restored = await restoreCameraWiFiWithRetry(waitBetween: {}) {
            attempts += 1
            throw CancellationError()
        }
        #expect(!restored)
        #expect(attempts == 1)
    }
}
