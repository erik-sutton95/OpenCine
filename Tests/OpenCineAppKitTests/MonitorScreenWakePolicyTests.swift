import OpenCineAppKit
import Testing

@Suite struct MonitorScreenWakePolicyTests {
    @Test(arguments: [false, true], [false, true])
    func everyForegroundSurfaceHonorsThePreference(enabled: Bool, sceneActive: Bool) {
        #expect(MonitorScreenWakePolicy.keepAwake(enabled: enabled, sceneActive: sceneActive)
            == (enabled && sceneActive))
    }
}
