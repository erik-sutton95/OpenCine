import Foundation
import Testing

@testable import OpenCineDesktopKit

/// The "OpenCine" input shows the selected tab's slot: what the dock hands the driver.
@Suite struct VirtualCameraSelectionTests {
    private func table() -> VirtualCameraSlotTable {
        var table = VirtualCameraSlotTable()
        table.assign(moduleID: "nikon-z", displayName: "OpenCine Nikon Z")
        table.assign(moduleID: "pocket", displayName: "OpenCine Pocket")
        table.assign(moduleID: "luna", displayName: "OpenCine Luna")
        return table
    }

    @Test func selectionFollowsTheSelectedTabsSlot() {
        let table = table()
        #expect(VirtualCameraSelection(selectedModuleID: "pocket", table: table).slot?.number == 2)
        #expect(VirtualCameraSelection(selectedModuleID: "luna", table: table).slot?.number == 3)
        #expect(VirtualCameraSelection(selectedModuleID: nil, table: table).slot == nil)
        #expect(VirtualCameraSelection(selectedModuleID: "unknown", table: table).slot == nil)
    }

    @Test func selectionCrossesTheWireUnchanged() {
        for slot in [nil] + VirtualCameraSlot.all.map(Optional.some) {
            let selection = VirtualCameraSelection(slot: slot)
            #expect(
                VirtualCameraSelectionWire.decode(VirtualCameraSelectionWire.encode(selection))
                    == selection)
        }
        #expect(VirtualCameraSelectionWire.encode(VirtualCameraSelection(slot: nil)) == "0")
    }

    @Test func driverRefusesAnythingButASlotOrNone() {
        for text in ["", "9", "-1", "12", "1.0", "one", "\u{0663}", "100000"] {
            #expect(VirtualCameraSelectionWire.decode(text) == nil, "\(text)")
        }
    }

    @Test func selectedInputIdentifiersAreFixedForeverAndApartFromSlots() {
        #expect(SelectedVirtualCamera.displayName == "OpenCine")
        #expect(SelectedVirtualCamera.legacyDeviceID == "OpenCine.Camera.Selected")
        #expect(SelectedVirtualCamera.deviceUUID.uuidString == "6F70656E-6369-4E65-8000-0000000000A0")
        #expect(
            SelectedVirtualCamera.sourceStreamUUID.uuidString
                == "6F70656E-6369-4E65-8000-0000000000A1")
        let slotIDs = Set(
            VirtualCameraSlot.all.flatMap { [$0.deviceUUID, $0.sourceStreamUUID, $0.sinkStreamUUID] })
        #expect(!slotIDs.contains(SelectedVirtualCamera.deviceUUID))
        #expect(!slotIDs.contains(SelectedVirtualCamera.sourceStreamUUID))
        #expect(VirtualCameraSelectionWire.selector != VirtualCameraSlotTableWire.selector)
    }
}
