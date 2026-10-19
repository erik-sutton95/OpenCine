import Foundation
import Testing

@testable import OpenCineNikon

@Suite("Saved Wi-Fi body wake before the handshake")
struct NikonBodyWakeTests {
    /// Answers from dial `answerOn` (1-based) on, and records every dial and pause.
    actor Probe {
        let answerOn: Int?
        private(set) var dialed: [String] = []
        private(set) var pauses: [Duration] = []
        init(answerOn: Int?) { self.answerOn = answerOn }

        func isAlive(_ host: String) -> Bool {
            dialed.append(host)
            guard let answerOn else { return false }
            return dialed.count >= answerOn
        }

        func sleep(_ duration: Duration) {
            pauses.append(duration)
        }
    }

    private func wait(_ probe: Probe) async -> NikonBodyWake.Outcome {
        await NikonBodyWake.awaitAnswer(
            host: "192.168.1.20", isAlive: { await probe.isAlive($0) },
            sleep: { await probe.sleep($0) })
    }

    @Test("An awake body goes straight on with one dial and no pause")
    func awakeBodyAnswersAtOnce() async {
        let probe = Probe(answerOn: 1)
        let outcome = await wait(probe)
        #expect(outcome == .answered(dials: 1))
        #expect(await probe.dialed == ["192.168.1.20"])
        #expect(await probe.pauses.isEmpty)
    }

    @Test("A waking body is dialled again until it answers")
    func wakingBodyAnswersOnALaterDial() async {
        let probe = Probe(answerOn: 4)
        let outcome = await wait(probe)
        #expect(outcome == .answered(dials: 4))
        #expect(await probe.pauses == Array(repeating: NikonBodyWake.interval, count: 3))
    }

    @Test("A silent body is bounded by the dial count, with no pause after the last dial")
    func silentBodyIsBounded() async {
        let probe = Probe(answerOn: nil)
        let outcome = await wait(probe)
        #expect(outcome == .silent(dials: NikonBodyWake.dials))
        #expect(!outcome.answered)
        #expect(await probe.dialed.count == NikonBodyWake.dials)
        #expect(await probe.pauses.count == NikonBodyWake.dials - 1)
    }

    @Test("A cancelled pause ends the wait as silent without another dial")
    func cancelledPauseStops() async {
        let probe = Probe(answerOn: nil)
        let outcome = await NikonBodyWake.awaitAnswer(
            host: "192.168.1.20", isAlive: { await probe.isAlive($0) },
            sleep: { _ in throw CancellationError() })
        #expect(outcome == .silent(dials: 1))
        #expect(await probe.dialed.count == 1)
    }

    @Test("The silent copy names the camera and both real causes, never a socket timeout")
    func silentCopyIsHonest() {
        let named = NikonBodyWake.silentMessage(deviceName: "ZR_6002199")
        #expect(named.hasPrefix("ZR_6002199 didn't answer on this network."))
        #expect(named.contains("asleep"))
        #expect(named.contains("same Wi‑Fi"))
        #expect(!named.lowercased().contains("timed out"))
        #expect(NikonBodyWake.silentMessage(deviceName: " ").hasPrefix("The camera didn't answer"))
        #expect(
            NikonBodyWake.wakingMessage(deviceName: "ZR_6002199")
                == "Waiting for ZR_6002199 to answer on the network…")
    }
}
