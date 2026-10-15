#if os(iOS)
import OpenCineAppKitApple
import Testing

@MainActor @Suite struct MonitorScreenWakeOwnerTests {
    @Test func sceneAndPreferenceChangesHaveOneDeduplicatedNativeOwner() {
        var requests: [Bool] = []
        let owner = MonitorScreenWakeOwner(apply: { requests.append($0) })
        owner.update(enabled: false, sceneActive: true)
        owner.update(enabled: false, sceneActive: true)
        owner.update(enabled: true, sceneActive: true)
        owner.update(enabled: true, sceneActive: false)
        owner.update(enabled: true, sceneActive: false)
        owner.update(enabled: true, sceneActive: true)
        owner.retire()
        owner.retire()
        #expect(requests == [false, true, false, true, false])
        owner.update(enabled: false, sceneActive: true)
        owner.update(enabled: true, sceneActive: true)
        #expect(requests == [false, true, false, true, false, true])
    }
}
#endif
