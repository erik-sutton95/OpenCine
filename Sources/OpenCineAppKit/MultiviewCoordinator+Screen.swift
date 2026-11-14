import Foundation
import OpenCineCore

/// The shared screen's rules over the coordinator: what the Add list offers, the close copy, the
/// Auto LUT toggles, the stage tiles with the app's readings and the tools the app supports. Each
/// follows a capability (the commissioner's presence, the camera policy, the host's values), never
/// a brand. Kotlin twin: `MultiviewCoordinatorScreen.kt`.
@available(macOS 14, *)
extension MultiviewCoordinator {
    /// `slot`'s camera name, nil while the slot is empty.
    public func cameraName(slot: Int) -> String? {
        members[slot].camera.map { describe($0).name }
    }

    /// Found cameras the Add list offers: those the policy lets join (experimentally if need be)
    /// and that are not members. One without a picture says so and joins experimentally.
    public func pickerRows() -> [MultiviewPickerRow] {
        addable.map { camera in
            let record = describe(camera)
            let preview = policy.hasPreview(camera)
            return MultiviewPickerRow(
                id: record.id.uuidString, title: record.name,
                detail: preview ? nil : MultiviewCopy.previewUnavailable, limited: !preview)
        }
    }

    /// The Add list's footer for this stage's network.
    public var pickerFooter: String {
        MultiviewCopy.pickerFooter(network: ssid, commissioned: commissioner != nil)
    }

    /// Adds the camera of the Add list's row `id` to `slot` (experimentally when it shows no
    /// picture); false when the row is gone.
    @discardableResult public func enqueueAdd(pickerRow id: String, slot: Int) -> Bool {
        guard let camera = addable.first(where: { describe($0).id.uuidString == id }) else {
            return false
        }
        enqueueAdd(camera, slot: slot, experimental: !policy.hasPreview(camera))
        return true
    }

    private var addable: [Camera] {
        let members = Set(members.compactMap { $0.camera.map { describe($0).id } })
        return found.filter { camera in
            if case .refused = policy.qualification(camera, experimental: true) { return false }
            return !members.contains(describe(camera).id)
        }
    }

    /// Whether closing returns cameras to their own networks: only an app that moved them there.
    public var networkRestore: MultiviewNetworkRestore {
        commissioner == nil ? .none : .cameraNetworks
    }

    /// The network wizard may scan through a nearby camera.
    public var scansNetworks: Bool { commissioner?.scansNetworks ?? false }

    /// Toggles `slot`'s Auto LUT and saves the choice.
    public func toggleLUT(slot: Int) {
        members[slot].lutEnabled.toggle()
        host?.lutChanged(slot: slot)
        persistStage()
    }

    /// The LUT tool: every member on, unless all already are (then every member off).
    public func toggleLUT() {
        let slots = memberSlots
        let enabled = !slots.allSatisfy { members[$0].lutEnabled }
        for slot in slots where members[slot].lutEnabled != enabled {
            members[slot].lutEnabled = enabled
            host?.lutChanged(slot: slot)
        }
        persistStage()
    }

    /// Some member grades its picture.
    public var lutOn: Bool { memberSlots.contains { members[$0].lutEnabled } }

    /// The stage's values for `slot` from the app's readings (or the camera's name alone), nil
    /// while it is empty. The Auto LUT option shows only where the app grades pictures.
    public func stageTile(_ slot: Int) -> MultiviewTile? {
        guard let camera = members[slot].camera else { return nil }
        let readings =
            host?.readings(slot: slot)
            ?? MultiviewTileReadings(
                name: describe(camera).name, hasPicture: members[slot].publishing)
        guard var tile = tile(slot, readings) else { return nil }
        if host?.appliesAutoLUT != true {
            tile.actions.removeAll { $0.id == MultiviewCameraAction.lut }
        }
        return tile
    }

    /// The program camera's readouts (Center stage), nil while its slot is empty or the app reads
    /// nothing from it.
    public var programReadouts: [MultiviewReadout]? {
        guard !members.isEmpty else { return nil }
        let slot = min(members.count - 1, max(0, presentation.selected))
        guard members[slot].camera != nil else { return nil }
        return host?.readings(slot: slot)?.readouts
    }

    /// Slots whose camera settings the popup edits: every member, when the app edits settings.
    public var cameraSettingsSlots: [Int] { host?.editsCameraSettings == true ? memberSlots : [] }

    /// The tools the stage offers: CAMERA where the app edits settings, LUT where it grades.
    public var toolAvailability: MultiviewToolAvailability {
        MultiviewToolAvailability(
            cameraSettingsSlots: Set(cameraSettingsSlots),
            pictureLUTSlots: host?.appliesAutoLUT == true ? Set(memberSlots) : [])
    }
}
