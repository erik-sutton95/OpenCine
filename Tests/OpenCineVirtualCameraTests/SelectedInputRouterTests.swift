import Foundation
import OpenCineDesktopKit
import Testing

@testable import OpenCineVirtualCamera

/// "OpenCine" shows the selected slot under that slot's own rules, and a new selection lands on the
/// very next output.
@Suite struct SelectedInputRouterTests {
    final class Picture {}

    private let now: UInt64 = 1_000_000_000
    private let pocket = VirtualCameraSlot(number: 2)!
    private let luna = VirtualCameraSlot(number: 3)!

    /// Slot policies as the driver holds them, each with a live producer and one picture.
    private func liveSlots() -> (policies: [Int: FramePolicy<Picture>], pictures: [Int: Picture]) {
        var policies: [Int: FramePolicy<Picture>] = [:]
        var pictures: [Int: Picture] = [:]
        for slot in [pocket, luna] {
            let policy = FramePolicy<Picture>()
            let producer = UUID()
            let picture = Picture()
            let epoch = policy.claim(producer)!
            #expect(policy.offer(picture, producer: producer, generation: epoch, timestamp: now, now: now))
            policies[slot.number] = policy
            pictures[slot.number] = picture
        }
        return (policies, pictures)
    }

    private func shown(_ router: SelectedInputRouter<Picture>, _ policies: [Int: FramePolicy<Picture>])
        -> SelectedInputRouter<Picture>.Picture
    {
        router.output(now: now + 1_000_000) { policies[$0.number] }
    }

    @Test func switchingTheSelectionSwitchesThePictureOnTheNextOutput() {
        let (policies, pictures) = liveSlots()
        let router = SelectedInputRouter<Picture>()
        #expect(router.select(VirtualCameraSelection(slot: pocket)))
        guard case .frame(let first, _) = shown(router, policies).output else {
            Issue.record("the selected live slot's frame is shown")
            return
        }
        #expect(first === pictures[pocket.number])
        #expect(router.select(VirtualCameraSelection(slot: luna)))
        let next = shown(router, policies)
        #expect(next.slot == luna)
        guard case .frame(let second, _) = next.output else {
            Issue.record("the newly selected slot's frame is shown at once")
            return
        }
        #expect(second === pictures[luna.number])
        #expect(!router.select(VirtualCameraSelection(slot: luna)))
    }

    @Test func aSelectedCameraThatIsNotLiveShowsItsSlotsSlate() {
        let router = SelectedInputRouter<Picture>()
        router.select(VirtualCameraSelection(slot: pocket))
        let idle = FramePolicy<Picture>()
        let picture = router.output(now: now) { _ in idle }
        #expect(picture.slot == pocket)
        guard case .slate(.feedOff) = picture.output else {
            Issue.record("no producer: the slot's not-connected slate")
            return
        }
        let producer = UUID()
        _ = idle.claim(producer)
        guard case .slate(.noFeed) = router.output(now: now, policy: { _ in idle }).output else {
            Issue.record("a producer without picture: the slot's waiting slate")
            return
        }
    }

    @Test func noSelectionOrAnUnpublishedSlotShowsTheInputsOwnSlate() {
        let (policies, _) = liveSlots()
        let router = SelectedInputRouter<Picture>()
        var picture = shown(router, policies)
        #expect(picture.slot == nil)
        guard case .slate(.feedOff) = picture.output else {
            Issue.record("nothing selected: not connected")
            return
        }
        router.select(VirtualCameraSelection(slot: VirtualCameraSlot(number: 5)!))
        picture = shown(router, policies)
        #expect(picture.slot == nil)
        guard case .slate(.feedOff) = picture.output else {
            Issue.record("a slot the driver has not published: not connected")
            return
        }
    }

    @Test func showingASlotLeavesItsOwnInputsDeliveryAlone() {
        let (policies, _) = liveSlots()
        let router = SelectedInputRouter<Picture>()
        router.select(VirtualCameraSelection(slot: pocket))
        for _ in 0..<3 { _ = shown(router, policies) }
        let own = policies[pocket.number]!
        guard case .frame(_, repeated: false) = own.output(now: now + 1_000_000) else {
            Issue.record("the slot's own input still sees its frame as new")
            return
        }
        #expect(own.repeats == 0)
    }
}
