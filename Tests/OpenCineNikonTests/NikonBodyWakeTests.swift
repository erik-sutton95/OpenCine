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

    /// A monotonic clock a test moves by hand.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed: Duration = .zero
        var now: Duration { lock.withLock { elapsed } }
        func advance(_ by: Duration) { lock.withLock { elapsed += by } }
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
        // These dials end at once, so each pause is the rest of its slot.
        #expect(await probe.pauses.count == 3)
    }

    @Test("Dials that fail at once still span the whole wait, one slot each")
    func instantFailuresFillTheirSlots() async {
        // Hardware pass 2026-10-25 (1.11): after a failed address resolution Darwin refuses every
        // dial to the host for 20 s without sending a frame, so ten instant failures used to end
        // the wait in about 5 s. The wait must stay one slot per dial.
        let probe = Probe(answerOn: nil)
        let outcome = await wait(probe)
        #expect(outcome == .silent(dials: NikonBodyWake.dials))
        let total = await probe.pauses.reduce(Duration.zero, +)
        let floor = (NikonBodyWake.slot - .milliseconds(100)) * (NikonBodyWake.dials - 1)
        #expect(total >= floor)
        #expect(total <= NikonBodyWake.slot * (NikonBodyWake.dials - 1))
    }

    @Test("A dial that used its whole deadline is followed by the shortest pause only")
    func slowDialsPauseOnlyTheInterval() async {
        let clock = FakeClock()
        let probe = Probe(answerOn: nil)
        let outcome = await NikonBodyWake.awaitAnswer(
            host: "192.168.1.20",
            isAlive: { host in
                clock.advance(.milliseconds(1_500))
                return await probe.isAlive(host)
            },
            now: { clock.now },
            sleep: { await probe.sleep($0) })
        #expect(outcome == .silent(dials: NikonBodyWake.dials))
        #expect(
            await probe.pauses
                == Array(repeating: NikonBodyWake.interval, count: NikonBodyWake.dials - 1))
    }

    @Test("A dial cut short pauses for the rest of its slot")
    func pauseIsTheRestOfTheSlot() {
        let slot = NikonBodyWake.slot
        let interval = NikonBodyWake.interval
        #expect(NikonBodyWake.pause(after: .zero, interval: interval, slot: slot) == slot)
        #expect(
            NikonBodyWake.pause(after: .milliseconds(300), interval: interval, slot: slot)
                == .milliseconds(1_700))
        #expect(
            NikonBodyWake.pause(after: .milliseconds(1_900), interval: interval, slot: slot)
                == interval)
        #expect(NikonBodyWake.pause(after: .seconds(5), interval: interval, slot: slot) == interval)
    }

    @Test("A connect that timed out counts against the wake, so the operator sees one wait")
    func connectTimeCountsAgainstTheWake() async {
        let clock = FakeClock()
        let probe = DialProbe(answerOn: nil)
        do {
            _ = try await NikonBodyWake.dial(
                host: "192.168.1.20",
                isAlive: { await probe.isAlive($0) },
                now: { clock.now },
                sleep: { clock.advance($0) },
                dial: { () -> String in
                    clock.advance(.seconds(10))
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                })
            Issue.record("a silent body must not connect")
        } catch {
            #expect(error is NikonBodyWake.SilentError)
        }
        #expect(await probe.aliveDials == 5)
        #expect(clock.now == .seconds(10) + NikonBodyWake.slot * 4)
        #expect(NikonBodyWake.dialsLeft(after: .zero, dials: 10, slot: .seconds(2)) == 10)
        #expect(NikonBodyWake.dialsLeft(after: .seconds(60), dials: 10, slot: .seconds(2)) == 1)
    }

    @Test("The blocking wake also counts the connect's time")
    func blockingConnectTimeCountsAgainstTheWake() {
        let probe = BlockingDialProbe(answerOn: nil)
        let clock = PauseLog()
        var elapsed: TimeInterval = 0
        do {
            _ = try NikonBodyWake.dialBlocking(
                host: "192.168.1.20",
                isAlive: { _ in probe.isAlive() },
                now: { elapsed },
                sleep: { elapsed += $0; clock.append($0) },
                dial: { () -> String in
                    elapsed += 6
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                })
            Issue.record("a silent body must not connect")
        } catch {
            #expect(error is NikonBodyWake.SilentError)
        }
        #expect(clock.values.count == 6)
    }

    @Test("The blocking wait used by Android also spans one slot per instant dial")
    func blockingInstantFailuresFillTheirSlots() {
        let probe = BlockingDialProbe(answerOn: nil)
        let pauses = PauseLog()
        do {
            _ = try NikonBodyWake.dialBlocking(
                host: "192.168.1.20",
                isAlive: { _ in probe.isAlive() },
                now: { 100 },
                sleep: { pauses.append($0) },
                dial: { () -> String in
                    _ = probe.attempt()
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                })
            Issue.record("a silent body must not connect")
        } catch {
            #expect(error is NikonBodyWake.SilentError)
        }
        #expect(pauses.values == Array(repeating: 2.0, count: NikonBodyWake.dials - 1))
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

    @Test("The wake's progress maps to the waiting step, then the handshake")
    func progressPhases() {
        #expect(NikonBodyWake.Progress.waiting.phase == .discovering)
        #expect(NikonBodyWake.Progress.answered.phase == .handshaking)
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

    // A dial that failed at the link layer. The socket layer wraps only the TCP connect this way;
    // a PTP-IP handshake failure is never a `DialFailure`, so it cannot reach the wake.
    private enum DialError: Error, Equatable, Sendable {
        case unreachable
        case rejected
    }

    /// Counts the dial, wake and liveness calls a `dial` run makes.
    private actor DialProbe {
        let answerOn: Int?
        private(set) var attempts = 0
        private(set) var wakes = 0
        private(set) var aliveDials = 0

        init(answerOn: Int?) { self.answerOn = answerOn }

        func attempt() -> Int {
            attempts += 1
            return attempts
        }

        func woke() { wakes += 1 }

        func isAlive(_ host: String) -> Bool {
            aliveDials += 1
            guard let answerOn else { return false }
            return aliveDials >= answerOn
        }
    }

    @Test("A dial that fails unreachable once wakes the body and retries exactly once")
    func unreachableDialWakesAndRetriesOnce() async throws {
        let probe = DialProbe(answerOn: 1)
        let value = try await NikonBodyWake.dial(
            host: "192.168.1.20",
            isAlive: { await probe.isAlive($0) },
            onWake: { await probe.woke() },
            dial: {
                let attempt = await probe.attempt()
                guard attempt > 1 else {
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                }
                return "connected"
            })
        #expect(value == "connected")
        #expect(await probe.attempts == 2)
        #expect(await probe.wakes == 1)
        #expect(await probe.aliveDials == 1)
    }

    @Test("A silent wake ends with the honest asleep-or-off-network error and no retry")
    func silentWakeEndsHonestly() async {
        let probe = DialProbe(answerOn: nil)
        do {
            _ = try await NikonBodyWake.dial(
                host: "192.168.1.20", deviceName: "ZR_6002199",
                isAlive: { await probe.isAlive($0) },
                sleep: { _ in },
                dial: { () -> String in
                    _ = await probe.attempt()
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                })
            Issue.record("a silent body must not connect")
        } catch let error as NikonBodyWake.SilentError {
            #expect(error.errorDescription == NikonBodyWake.silentMessage(deviceName: "ZR_6002199"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await probe.attempts == 1)
        #expect(await probe.aliveDials == NikonBodyWake.dials)
    }

    @Test("A second unreachable failure surfaces the honest silent error and never wakes again")
    func secondFailureDoesNotWakeAgain() async {
        let probe = DialProbe(answerOn: 1)
        do {
            _ = try await NikonBodyWake.dial(
                host: "192.168.1.20", deviceName: "ZR_6002199",
                isAlive: { await probe.isAlive($0) },
                onWake: { await probe.woke() },
                dial: { () -> String in
                    _ = await probe.attempt()
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                })
            Issue.record("a second failure must surface")
        } catch let error as NikonBodyWake.SilentError {
            #expect(error.errorDescription == NikonBodyWake.silentMessage(deviceName: "ZR_6002199"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await probe.attempts == 2)
        #expect(await probe.wakes == 1)
    }

    @Test("A refused or rejected dial never wakes the body")
    func otherDialFailuresNeverWake() async {
        let probe = DialProbe(answerOn: 1)
        do {
            _ = try await NikonBodyWake.dial(
                host: "192.168.1.20",
                isAlive: { await probe.isAlive($0) },
                onWake: { await probe.woke() },
                dial: { () -> String in
                    _ = await probe.attempt()
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.rejected, wakeWorthy: false)
                })
            Issue.record("a rejected dial must surface")
        } catch let error as DialError {
            #expect(error == .rejected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await probe.attempts == 1)
        #expect(await probe.wakes == 0)
        #expect(await probe.aliveDials == 0)
    }

    @Test("A body the pre-dial wake already heard costs one presence dial and no second wait")
    func preDialWakeAndDialWakeDoNotStack() async throws {
        // The app's saved-setup step (#91) asks the network before dialling an unseen setup; the
        // dial's own wake then runs only if the dial still fails at the link layer. A body the
        // first step just heard answers the dial wake's first presence dial, so the two never
        // stack into a second bounded wait.
        let probe = DialProbe(answerOn: 1)
        let pre = await NikonBodyWake.awaitAnswer(
            host: "192.168.1.20", isAlive: { await probe.isAlive($0) },
            sleep: { _ in Issue.record("an answering body needs no pause") })
        #expect(pre == .answered(dials: 1))
        let value = try await NikonBodyWake.dial(
            host: "192.168.1.20",
            isAlive: { await probe.isAlive($0) },
            onWake: { await probe.woke() },
            sleep: { _ in Issue.record("an answering body needs no pause") },
            dial: {
                guard await probe.attempt() > 1 else {
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                }
                return "connected"
            })
        #expect(value == "connected")
        #expect(await probe.aliveDials == 2)
        #expect(await probe.attempts == 2)
        #expect(await probe.wakes == 1)
    }

    @Test("The blocking dial used by Android wakes and retries exactly once")
    func blockingDialWakesAndRetriesOnce() throws {
        let probe = BlockingDialProbe(answerOn: 1)
        let value = try NikonBodyWake.dialBlocking(
            host: "192.168.1.20", dials: 1, interval: 0,
            isAlive: { _ in probe.isAlive() },
            onWake: { probe.woke() },
            dial: {
                guard probe.attempt() > 1 else {
                    throw NikonBodyWake.DialFailure(
                        underlying: DialError.unreachable, wakeWorthy: true)
                }
                return "connected"
            })
        #expect(value == "connected")
        #expect(probe.attempts == 2)
        #expect(probe.wakes == 1)
    }
}

private final class BlockingDialProbe: @unchecked Sendable {
    private let answerOn: Int?
    private let lock = NSLock()
    private var count = 0
    private var wakeCount = 0
    private var aliveCount = 0

    init(answerOn: Int?) { self.answerOn = answerOn }

    func attempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func woke() {
        lock.lock()
        wakeCount += 1
        lock.unlock()
    }

    func isAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        aliveCount += 1
        guard let answerOn else { return false }
        return aliveCount >= answerOn
    }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var wakes: Int {
        lock.lock()
        defer { lock.unlock() }
        return wakeCount
    }
}

private final class PauseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { log } }
    func append(_ value: TimeInterval) { lock.withLock { log.append(value) } }
}
