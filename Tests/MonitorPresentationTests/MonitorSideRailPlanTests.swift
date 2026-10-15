import Testing

@testable import MonitorPresentation

struct MonitorSideRailPlanTests {
    @Test func everyPreferenceAndSafetyCombinationPreservesVisibility() {
        // Exhaustive former sideRailPlan truth table, including all-hidden and pending record.
        for bits in 0..<256 {
            func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
            let plan = MonitorSideRailPlan(
                lockVisible: bit(0), batteriesVisible: bit(1), recordVisible: bit(2),
                mediaVisible: bit(3), settingsVisible: bit(4), settingsReachable: bit(5),
                interfaceLocked: bit(6), recordingOrPending: bit(7))
            #expect(plan.lock == (bit(0) || bit(6)))
            #expect(plan.batteries == bit(1))
            #expect(plan.disp)
            #expect(plan.record == (bit(2) || bit(7)))
            #expect(plan.media == bit(3))
            #expect(plan.settings == (bit(4) || !bit(5)))
            #expect(!plan.isEmpty)
        }
    }
}
