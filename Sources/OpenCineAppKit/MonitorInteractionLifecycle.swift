import OpenCineCore

/// Facts that admit live operator input. A cover borrows the camera; it does not close it.
public struct MonitorInteractionContext: Equatable, Sendable {
    public var locked: Bool
    public var covered: Bool
    public var editing: Bool
    public var clean: Bool
    public var toolbarMounted: Bool
    public var transientPanelPresented: Bool
    public var camera: CameraSessionID?
    public var orientationRevision: Int

    public init(locked: Bool = false, covered: Bool = false, editing: Bool = false,
        clean: Bool = false, toolbarMounted: Bool = true, transientPanelPresented: Bool = false,
        camera: CameraSessionID? = nil,
        orientationRevision: Int = 0) {
        self.locked = locked; self.covered = covered; self.editing = editing
        self.clean = clean; self.toolbarMounted = toolbarMounted
        self.transientPanelPresented = transientPanelPresented
        self.camera = camera; self.orientationRevision = orientationRevision
    }
    public var inputBlock: MonitorInputBlock? {
        if locked { return .lock }
        if covered { return .cover }
        if editing { return .edit }
        return nil
    }
}

public enum MonitorInputBlock: Equatable, Sendable { case lock, cover, edit, disappeared }
public enum MonitorInputAdmission: Equatable, Sendable {
    case blocked(MonitorInputBlock), resumed
}

/// A single transition retires operator presentation before adapters change input admission.
/// It never owns the camera session or emits a camera command.
public struct MonitorInteractionTransition: Equatable, Sendable {
    public let dismissTransients: Bool
    public let retireReadout: Bool
    public let collapseAssists: Bool
    public let inputAdmission: MonitorInputAdmission?
    /// A different camera replaced the previous one: per-camera readout choices start over.
    public var cameraReplaced = false
}

/// Shared lock, cover, chrome-edit, clean-view, rotation and replacement lifecycle.
/// The same transition is consumed by SwiftUI and Compose, including initial blocked mounts.
public struct MonitorInteractionLifecycle: Sendable {
    public private(set) var context: MonitorInteractionContext?
    public init() {}

    public mutating func update(_ next: MonitorInteractionContext) -> MonitorInteractionTransition {
        let previous = context
        context = next
        let replaced = previous != nil && previous?.camera != next.camera
        // A cover borrows the monitor: an open picker stays, hidden and inert, and returns
        // with its state. Lock, chrome edit, clean view and a new camera still dismiss it.
        let enteredBlock = next.inputBlock != nil && previous?.inputBlock != next.inputBlock
            && (next.inputBlock != .cover || previous == nil)
        let enteredCover = next.covered && previous?.covered != true
        let enteredClean = next.clean && previous?.clean != true
        let enteredEdit = next.editing && previous?.editing != true
        let dismiss = replaced || enteredBlock || enteredClean || enteredEdit
        let rotated = previous != nil && previous?.orientationRevision != next.orientationRevision
        let admission: MonitorInputAdmission?
        if previous == nil || previous?.inputBlock != next.inputBlock || replaced {
            admission = next.inputBlock.map(MonitorInputAdmission.blocked) ?? .resumed
        } else { admission = nil }
        return MonitorInteractionTransition(dismissTransients: dismiss,
            // Held input (a quick drag in flight) never survives a turn or a cover.
            retireReadout: dismiss || rotated || enteredCover,
            collapseAssists: dismiss || !next.toolbarMounted || next.transientPanelPresented,
            inputAdmission: admission, cameraReplaced: replaced)
    }

    public mutating func close() -> MonitorInteractionTransition {
        context = nil
        return MonitorInteractionTransition(dismissTransients: true, retireReadout: true,
            collapseAssists: true, inputAdmission: .blocked(.disappeared))
    }
}
