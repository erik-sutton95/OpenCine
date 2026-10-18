import Testing
@testable import OpenCineAppKit

@Suite struct MultiviewToolAvailabilityTests {
    @Test func explicitEmptyServicesNeverInferToolsFromOccupiedTiles() {
        let availability = MultiviewToolAvailability()
        #expect(availability.offeredTools(from: [.camera, .lut, .layout, .fit], occupiedSlots: [0, 1]) == [.layout, .fit])
        #expect(availability.cameraSettingsSlot(selected: 0, occupiedSlots: [0, 1]) == nil)
        #expect(availability.pictureLUTSlot(selected: 0, occupiedSlots: [0, 1]) == nil)
    }

    @Test func commandOnlyAndRenderOnlyMembersOfferTheirActualServices() {
        let commands = MultiviewToolAvailability(cameraSettingsSlots: [0])
        let rendering = MultiviewToolAvailability(pictureLUTSlots: [1])
        #expect(commands.offeredTools(from: [.lut, .layout, .camera, .fit], occupiedSlots: [0]) == [.layout, .camera, .fit])
        #expect(rendering.offeredTools(from: [.camera, .fit, .lut, .layout], occupiedSlots: [1]) == [.fit, .lut, .layout])
    }

    @Test func staleAndInvalidServiceSlotsCannotOfferAnAdapter() {
        let stale = MultiviewToolAvailability(cameraSettingsSlots: [-1, 2, 99], pictureLUTSlots: [2])
        #expect(stale.offeredTools(from: [.camera, .layout, .lut, .fit], occupiedSlots: [0, 1]) == [.layout, .fit])
        #expect(stale.cameraSettingsSlot(selected: 2, occupiedSlots: [0, 1]) == nil)
    }

    @Test func mixedMembersSelectTheCurrentAdmittedSlotThenFirstValidFallback() {
        let availability = MultiviewToolAvailability(cameraSettingsSlots: [1, 3], pictureLUTSlots: [2])
        #expect(availability.offeredTools(from: [.lut, .camera, .fit, .layout], occupiedSlots: [0, 1, 2, 3]) == [.lut, .camera, .fit, .layout])
        #expect(availability.cameraSettingsSlot(selected: 3, occupiedSlots: [0, 1, 2, 3]) == 3)
        #expect(availability.cameraSettingsSlot(selected: 0, occupiedSlots: [0, 1, 2, 3]) == 1)
        #expect(availability.cameraSettingsSlot(selected: 3, occupiedSlots: [0, 1, 2]) == 1)
        #expect(availability.pictureLUTSlot(selected: 0, occupiedSlots: [0, 1, 2]) == 2)
    }
}
