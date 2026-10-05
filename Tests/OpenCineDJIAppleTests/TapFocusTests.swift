import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED continuation-controlled actual request sequence; no sleeps or transport.
@Suite @MainActor
struct DJIAppleTapFocusTests {
    private final class Endpoint {}

    @MainActor private final class Peer {
        let first = Endpoint()
        let second = Endpoint()
        var binding: DjiAppleSettingsBinding!
        var prepares: [Duml.Frame] = []
        var requests: [(Duml.Frame, String, Duration)] = []
        var replies: [CheckedContinuation<Bool, Never>] = []
        var prepared: [(Duml.Frame, UInt16)] = []
        var onPrepare: (() -> Void)?
        var onPrepared: (() -> Void)?
        lazy var owner = DjiAppleTapFocus(
            binding: { [unowned self] in binding },
            sendPrepare: { [unowned self] frame in
                prepares.append(frame)
                onPrepare?()
                return 42
            },
            request: { [unowned self] frame, name, timeout in
                requests.append((frame, name, timeout))
                return await withCheckedContinuation { replies.append($0) }
            },
            prepared: { [unowned self] frame, sequence in
                prepared.append((frame, sequence))
                onPrepared?()
            })

        init() { binding = .init(endpoint: ObjectIdentifier(first), controlGeneration: 1) }
        func settle() async { for _ in 0..<50 { await Task.yield() } }
        func reply(_ success: Bool) async {
            #expect(!replies.isEmpty)
            guard !replies.isEmpty else { return }
            replies.removeFirst().resume(returning: success)
            await settle()
        }
        func finish() async {
            owner.retire()
            while !replies.isEmpty { await reply(false) }
            await settle()
        }
    }

    @Test func prepareNeverWaitsForACKAndOriginalFourWritesAndTimeoutsStayExact() async {
        let p = Peer()
        p.owner.start(x: 0.511, y: 0.498)
        await p.settle()
        #expect(p.prepares == [Commands.tapFocusPrepare()])
        #expect(p.prepared.count == 1 && p.prepared[0].1 == 42)
        #expect(p.requests.count == 1 && p.requests[0].0 == Commands.tapFocusPoint(0.511, 0.498))
        await p.reply(true)
        #expect(p.requests.count == 2 && p.requests[1].0 == Commands.tapFocusLiveHint())
        await p.reply(true)
        #expect(p.requests.count == 3 && p.requests[2].0 == Commands.tapFocusCommit(0.511, 0.498))
        #expect(p.requests.map { $0.1 } == ["Focus region", "AE hint", "Focus"])
        #expect(p.requests.allSatisfy { $0.2 == .milliseconds(800) })
        await p.reply(true)
        await p.finish()
    }

    @Test func refusedPointSuppressesHintAndCommitWhileRefusedHintStillCommits() async {
        let rejected = Peer()
        rejected.owner.start(x: 0.25, y: 0.75)
        await rejected.settle()
        await rejected.reply(false)
        #expect(rejected.requests.count == 1)
        await rejected.finish()
        let hint = Peer()
        hint.owner.start(x: 0.25, y: 0.75)
        await hint.settle()
        await hint.reply(true)
        await hint.reply(false)
        #expect(hint.requests.count == 3)
        #expect(hint.requests[2].0 == Commands.tapFocusCommit(0.25, 0.75))
        await hint.finish()
    }

    @Test func replacedTapRejectsOldReplyAndCannotRetireSuccessorSequence() async {
        let p = Peer()
        p.owner.start(x: 0.1, y: 0.2)
        await p.settle()
        p.owner.start(x: 0.7, y: 0.8)
        await p.settle()
        #expect(p.prepares.count == 2 && p.requests.count == 2)
        await p.reply(true)
        #expect(p.requests.count == 2)
        await p.reply(true)
        #expect(p.requests.count == 3 && p.requests[2].0 == Commands.tapFocusLiveHint())
        p.owner.retire()
        await p.reply(true)
        #expect(p.requests.count == 3)
        await p.finish()
    }

    @Test func changedEndpointOrControlGenerationRejectsCapturedContinuation() async {
        for endpointChange in [false, true] {
            let p = Peer()
            p.owner.start(x: 0.1, y: 0.2)
            await p.settle()
            p.binding = .init(
                endpoint: ObjectIdentifier(endpointChange ? p.second : p.first),
                controlGeneration: 2)
            await p.reply(true)
            #expect(p.requests.count == 1)
            p.owner.start(x: 0.7, y: 0.8)
            await p.settle()
            #expect(p.requests.count == 2 && p.requests[1].0 == Commands.tapFocusPoint(0.7, 0.8))
            await p.finish()
        }
    }

    @Test func prepareNativeAndDiagnosticReentryCannotWritePointIntoSuccessor() async {
        for diagnostic in [false, true] {
            let p = Peer()
            let replace = {
                p.binding = .init(endpoint: ObjectIdentifier(p.second), controlGeneration: 2)
            }
            if diagnostic { p.onPrepared = replace } else { p.onPrepare = replace }
            p.owner.start(x: 0.1, y: 0.2)
            await p.settle()
            #expect(p.prepares.count == 1 && p.requests.isEmpty)
            #expect(p.prepared.count == (diagnostic ? 1 : 0))
            await p.finish()
        }
    }

    @Test func synchronousDiagnosticStartsSuccessorWithoutOutgoingPoint() async {
        let p = Peer()
        p.onPrepared = {
            p.onPrepared = nil
            p.owner.start(x: 0.7, y: 0.8)
        }
        p.owner.start(x: 0.1, y: 0.2)
        await p.settle()
        #expect(p.prepares.count == 2 && p.requests.count == 1)
        #expect(p.requests[0].0 == Commands.tapFocusPoint(0.7, 0.8))
        await p.finish()
    }

    @Test func retireDuringHintAndAbsentTransportNeverProduceExtraCommands() async {
        let p = Peer()
        p.owner.start(x: 0.1, y: 0.2)
        await p.settle()
        await p.reply(true)
        p.owner.retire()
        await p.reply(true)
        #expect(p.requests.count == 2)
        p.binding = .init(endpoint: nil, controlGeneration: 2)
        p.owner.start(x: 0.7, y: 0.8)
        await p.settle()
        #expect(p.prepares.count == 1 && p.requests.count == 2)
        await p.finish()
    }
}
