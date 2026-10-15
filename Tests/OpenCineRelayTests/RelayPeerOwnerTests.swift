import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayPeerOwnerTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test func refusedJoinCannotClaimParkedControlOrReceiveProtectedBytes() throws {
        var control = RelayHostControl()
        let first = UUID()
        control.register(first, name: "First", authorized: true)
        _ = control.introduce(
            first, hello: .init(version: 1, hostName: "First", watcherID: "saved"),
            authorized: true, now: start)
        #expect(control.request(first, allowsControl: true) == true)
        #expect(control.grantPending() == true)
        let retiring = try #require(control.admission(for: first))
        _ = control.drop(first, now: start)

        let replacement = UUID()
        let hello = RelayPeerHello(
            version: 1, hostName: "Replacement", passcode: "wrong", watcherID: "saved")
        control.register(replacement, name: hello.hostName, authorized: false)
        #expect(
            RelayJoinPolicy.refusal(
                hello: hello, profile: .sharedMonitor, requiredPasscode: "right",
                versionMismatchReason: "version")?.passcodeRequired == true)
        #expect(control.introduce(
                replacement, hello: hello, authorized: false, now: start.addingTimeInterval(1)) == false)
        #expect(control.request(replacement, allowsControl: true) == false)
        #expect(control.admission(for: replacement) == nil)
        #expect(!control.admits(retiring))
        var delivery = RelayPeerDelivery()
        #expect(delivery.admitFrame(isHEVC: true, isKeyframe: true, depth: 2) == .unavailable)
        #expect(delivery.admitState() == false)

        let accepted = RelayPeerHello(
            version: 1, hostName: "Replacement", passcode: "right", watcherID: "saved")
        #expect(
            RelayJoinPolicy.refusal(
                hello: accepted, profile: .sharedMonitor, requiredPasscode: "right",
                versionMismatchReason: "version") == nil)
        #expect(control.introduce(
                replacement, hello: accepted, authorized: true, now: start.addingTimeInterval(2)) == true)
        #expect(control.holder == replacement && control.holderName == "Replacement")
        #expect(control.admission(for: replacement) != nil)
    }

    @Test func versionAdmissionIsExplicitAndDoesNotReplaceDeployedPermissiveHost() {
        let hello = RelayPeerHello(version: 99, hostName: "Peer")
        #expect(
            RelayJoinPolicy.refusal(
                hello: hello, profile: .sharedMonitor, requiredPasscode: "",
                versionMismatchReason: "version")
                == .init(reason: "version", passcodeRequired: false))
        #expect(
            RelayJoinPolicy.refusal(
                hello: hello, profile: .sharedMonitor, requiredPasscode: "",
                versionMismatchReason: "version", requiresVersionMatch: false) == nil)
    }

    @Test func joinComparesPasscodesTrimmedAndKeepsEverySavedForm() {
        func refused(_ offered: String?, _ required: String) -> Bool {
            RelayJoinPolicy.refusal(
                hello: .init(version: 1, hostName: "Watcher", passcode: offered, watcherID: "w"),
                profile: .sharedMonitor, requiredPasscode: required,
                versionMismatchReason: "version")?.passcodeRequired == true
        }
        // Saved before the shared rule: four digits (OpenZCine), free text of any length and
        // untrimmed (OpenPocketCine, OpenInstaCine). Each still admits its watchers.
        for saved in ["0000", "4821", "a", "ab1", "set pass", " padded ", "pässwörd\n", "🎬🎬"] {
            #expect(!refused(saved, saved), "\(saved)")
            #expect(!refused(RelayJoinPolicy.normalizedPasscode(saved), saved), "\(saved)")
            #expect(refused("other", saved), "\(saved)")
            #expect(refused(nil, saved), "\(saved)")
        }
        #expect(!refused(" 1234\t", "1234"))
        #expect(!refused("1234", "\u{00A0}1234\u{2003}"))
        #expect(refused("12 34", "1234"))
        // Whitespace alone is an open broadcast, as the rule's empty entry is.
        #expect(!refused(nil, " \n"))
    }

    @Test func slowPeerHasIndependentDepthAndCannotBreakHealthyReferenceChain() {
        var slow = RelayPeerDelivery(authorized: true)
        var healthy = RelayPeerDelivery(authorized: true)
        #expect(slow.admitFrame(isHEVC: true, isKeyframe: true, depth: 2) == .send)
        #expect(slow.admitFrame(isHEVC: true, isKeyframe: false, depth: 2) == .send)
        #expect(slow.admitFrame(isHEVC: true, isKeyframe: false, depth: 2) == .saturated)
        #expect(slow.needsKeyframe && slow.inFlightFrames == 2)
        for _ in 0..<20 {
            #expect(
                healthy.admitFrame(isHEVC: true, isKeyframe: healthy.needsKeyframe, depth: 2)
                    == .send)
            healthy.completeFrame()
        }
        #expect(!healthy.needsKeyframe && healthy.inFlightFrames == 0)
        slow.completeFrame()
        #expect(slow.admitFrame(isHEVC: true, isKeyframe: false, depth: 2) == .needsKeyframe)
        #expect(slow.admitFrame(isHEVC: true, isKeyframe: true, depth: 2) == .send)
        #expect(!slow.needsKeyframe)

        var quality = RelayPeerDelivery(authorized: true)
        for index in 0..<4 {
            #expect(quality.admitFrame(isHEVC: true, isKeyframe: index == 0, depth: 4) == .send)
        }
        #expect(quality.admitFrame(isHEVC: true, isKeyframe: false, depth: 4) == .saturated)
        #expect(quality.admitState() == true)
        #expect(quality.admitState() == false)
        quality.completeState()
        #expect(quality.inFlightFrames == 4 && quality.admitState())
    }

    @Test func codecNegotiationAndRefusalRetirePictureAdmission() {
        var jpeg = RelayPeerDelivery(authorized: true)
        jpeg.acceptsHEVC = false
        #expect(jpeg.admitFrame(isHEVC: true, isKeyframe: true, depth: 2) == .wrongCodec)
        #expect(jpeg.inFlightFrames == 0 && jpeg.needsKeyframe)
        #expect(jpeg.admitFrame(isHEVC: false, isKeyframe: true, depth: 2, jpegOnly: true) == .send)
        jpeg.closing = true
        #expect(!jpeg.readyForFrame(depth: 2))
        #expect(jpeg.admitFrame(isHEVC: false, isKeyframe: true, depth: 2) == .unavailable)
        #expect(jpeg.admitState() == false)
        var hevc = RelayPeerDelivery(authorized: true)
        #expect(
            hevc.admitFrame(isHEVC: false, isKeyframe: true, depth: 2, jpegOnly: true)
                == .wrongCodec)
    }

    @Test func expiryCannotRevokeSuccessorGrantAndExactDeadlineDoesNotRestoreOldInstall() throws {
        var control = RelayHostControl()
        let first = UUID()
        let second = UUID()
        control.register(first, name: "First", authorized: true)
        _ = control.introduce(
            first, hello: .init(version: 1, hostName: "First", watcherID: "saved"),
            authorized: true, now: start)
        #expect(control.request(first, allowsControl: true) && control.grantPending())
        let dropCandidate10 = control.drop(first, now: start)
        let expiry = try #require(dropCandidate10)
        #expect(control.expire(expected: expiry, now: start.addingTimeInterval(19.999)) == false)
        control.register(second, name: "Second", authorized: true)
        #expect(control.request(second, allowsControl: true) && control.grantPending())
        #expect(control.expire(expected: expiry, now: start.addingTimeInterval(20)) == false)
        #expect(control.holder == second)
        control.reclaim()
        #expect(control.expire(expected: expiry, now: start.addingTimeInterval(21)) == false)

        control.resetSource()
        control.register(first, name: "First", authorized: true)
        _ = control.introduce(
            first, hello: .init(version: 1, hostName: "First", watcherID: "saved"),
            authorized: true, now: start)
        #expect(control.request(first, allowsControl: true) && control.grantPending())
        let dropCandidate14 = control.drop(first, now: start)
        let exactExpiry = try #require(dropCandidate14)
        control.register(second, name: "Second", authorized: true)
        #expect(control.introduce(
                second, hello: .init(version: 1, hostName: "Second", watcherID: "saved"),
                authorized: true, now: start.addingTimeInterval(20)) == false)
        #expect(control.expire(expected: exactExpiry, now: start.addingTimeInterval(20)) == true)
        #expect(control.holder == nil && control.holderName == nil)
    }

    @Test func revokedPeerAndSameIdentitySourceReplacementCannotDispatchOldCommand() throws {
        var control = RelayHostControl()
        let peer = UUID()
        let hello = RelayPeerHello(version: 1, hostName: "Same label", watcherID: "saved")
        control.register(peer, name: hello.hostName, authorized: true)
        _ = control.introduce(peer, hello: hello, authorized: true, now: start)
        #expect(control.request(peer, allowsControl: true) && control.grantPending())
        let command = try #require(control.admission(for: peer))
        #expect(control.admits(command))
        _ = control.introduce(peer, hello: hello, authorized: false, now: start)
        #expect(!control.admits(command) && control.holder == nil)
        #expect(control.drop(peer, now: start) == nil)
        control.resetSource()
        control.register(peer, name: hello.hostName, authorized: true)
        _ = control.introduce(peer, hello: hello, authorized: true, now: start)
        #expect(control.request(peer, allowsControl: true) && control.grantPending())
        let replacement = try #require(control.admission(for: peer))
        #expect(replacement.source != command.source && !control.admits(command))
        var dispatched = 0
        if control.admits(command) { dispatched += 1 }
        #expect(dispatched == 0)
        control.resetSource()
        if control.admits(replacement) { dispatched += 1 }
        #expect(dispatched == 0 && control.pendingName == nil)
    }

    @Test func retiredAndDuplicateCompletionsCannotReleaseSuccessorStageCredit() throws {
        var stages = RelayBroadcastStages(encodingDepth: 2, jpegDepth: 1)
        let admitCandidate17 = stages.admit(.encoding)
        let first = try #require(admitCandidate17)
        let admitCandidate18 = stages.admit(.encoding)
        _ = try #require(admitCandidate18)
        let admitCandidate19 = stages.admit(.jpeg)
        let jpeg = try #require(admitCandidate19)
        #expect(stages.admit(.encoding) == nil && stages.admit(.jpeg) == nil)
        #expect(stages.complete(first) == true)
        #expect(stages.complete(first) == false)
        let admitCandidate22 = stages.admit(.encoding)
        let blocked = try #require(admitCandidate22)
        stages.replace()
        let admitCandidate23 = stages.admit(.encoding)
        let successor = try #require(admitCandidate23)
        #expect(!stages.admits(first.stage))
        #expect(!stages.complete(blocked) && !stages.complete(jpeg))
        #expect(stages.inFlight(.encoding) == 1 && stages.inFlight(.jpeg) == 0)
        #expect(stages.complete(successor) == true)
        stages.close()
        #expect(!stages.complete(successor) && stages.admit(.encoding) == nil)
        #expect(stages.admit(.jpeg) == nil && !stages.isActive)
    }

    @Test func stopAndReentryUseRealLifetimeInsteadOfAddressOrName() {
        var lifetime = RelayConnectionLifetime()
        let first = lifetime.begin()
        #expect(lifetime.admits(first))
        lifetime.retire()
        #expect(!lifetime.admits(first))
        let replacement = lifetime.begin()
        #expect(first != replacement && lifetime.admits(replacement))
        #expect(!lifetime.admits(first))
    }

    @Test func passiveBrowseChurnPreservesShieldAndRetiresOldWindows() {
        var index = RelayDiscoveryIndex<String>(order: .name)
        let first = index.start()
        let plain = RelayDiscoveryRow(id: "same", name: "Camera", endpoint: "listing")
        let shield = RelayDiscoveryRow(
            id: "same", name: "Camera", endpoint: "txt",
            servedCameraHost: "192.168.1.20", isWatchable: false)
        #expect(index.replace([plain, plain], origin: "list", token: first) == true)
        #expect(index.replace([shield], origin: "txt", token: first) == true)
        #expect(index.results.count == 1 && index.results[0].endpoint == "txt")
        #expect(
            index.results[0].servedCameraHost == "192.168.1.20" && !index.results[0].isWatchable)
        #expect(index.replace([], origin: "list", token: first) == true)
        #expect(index.results.count == 1 && !index.results[0].isWatchable)
        #expect(index.replace([], origin: "txt", token: first) && index.results.isEmpty)
        index.stop()
        #expect(index.replace([shield], origin: "txt", token: first) == false)
        let successor = index.start()
        #expect(index.replace([plain], origin: "list", token: successor) == true)
        #expect(index.replace([shield], origin: "txt", token: first) == false)
        #expect(
            index.results.count == 1 && index.results[0].endpoint == "listing"
                && index.results[0].isWatchable)
    }
}
