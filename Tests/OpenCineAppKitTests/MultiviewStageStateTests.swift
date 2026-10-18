import Foundation
import MonitorPresentation
import Testing

@testable import OpenCineAppKit

@MainActor @Suite struct MultiviewStageStateTests {
    @available(macOS 14, *) @Test func presentationPreferencesSurviveRelaunch() throws {
        var saved: MultiviewStagePreferences?
        let state = MultiviewStageState(slotCount: 4)
        state.attachPersistence(
            load: { saved },
            save: {
                saved = $0
                return true
            })
        state.layout = .grid
        state.selected = 2
        state.fill = true
        state.clean = true
        state.toolsExpanded = true
        state.toolUsage.recordUse(of: "FIT", at: 100)
        let data = try JSONEncoder().encode(#require(saved))
        let restored = MultiviewStageState(slotCount: 4)
        restored.attachPersistence(
            load: { try? JSONDecoder().decode(MultiviewStagePreferences.self, from: data) },
            save: { _ in
                Issue.record("Loading must not write")
                return false
            })
        #expect(restored.preferences == state.preferences)
        #expect(restored.toolUsage.counts["FIT"] == 1)
    }

    @available(macOS 14, *) @Test func legacyPresentationCannotOverwriteNewerCommonPreferences() {
        let state = MultiviewStageState(slotCount: 4)
        state.attachPersistence(
            load: { .init(layout: .grid, selected: 2, fill: true) }, save: { _ in true })
        state.importLegacy(.init(layout: .centerStage, selected: 0))
        #expect(state.layout == .grid && state.selected == 2 && state.fill)
    }

    @available(macOS 14, *) @Test func failedSaveKeepsLiveStateAndPreviousStoredPreferences() {
        let stored = MultiviewStagePreferences(layout: .grid)
        let state = MultiviewStageState(slotCount: 4)
        state.attachPersistence(load: { stored }, save: { _ in false })
        state.fill = true
        #expect(state.fill)
        let restored = MultiviewStageState(slotCount: 4)
        restored.attachPersistence(load: { stored }, save: { _ in false })
        #expect(!restored.fill && restored.layout == .grid)
    }

    @available(macOS 14, *) @Test func qualifiedSlotCountBoundsRestoredAndEditedSelection() {
        let state = MultiviewStageState(slotCount: 2)
        state.attachPersistence(load: { .init(selected: 8) }, save: { _ in true })
        #expect(state.selected == 1)
        state.selected = -4
        #expect(state.selected == 0)
    }

    @available(macOS 14, *) @Test func missingCommonFieldsDecodeWithCompatibleDefaults() throws {
        let data = Data(#"{"layout":"2 × 2 grid","selected":2}"#.utf8)
        let value = try JSONDecoder().decode(MultiviewStagePreferences.self, from: data)
        #expect(value.layout == .grid && value.selected == 2)
        #expect(!value.fill && !value.clean && !value.toolsExpanded)
        #expect(value.toolUsage == MonitorToolUsage())
    }

    @available(macOS 14, *) @Test func closeCopyUsesOnlyTheTypedRestoreFact() {
        #expect(
            MultiviewNetworkRestore.none.closeQuestion == "Close Multiview? Recording continues.")
        #expect(
            MultiviewNetworkRestore.cameraNetworks.closeQuestion
                == "Close Multiview and return cameras to their own Wi-Fi? Recording continues.")
        #expect(MultiviewNetworkRestore.closeAction == "Close monitoring")
    }
}
