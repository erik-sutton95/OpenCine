import Foundation

/// Operator presentation state, separate from camera telemetry and native picture lifetime.
public struct MonitorScreenPresentation: Equatable, Sendable {
    public var visible: Bool
    public var interactive: Bool
    public var dimmed: Bool
    /// Hides control accessibility and blocks input; retained chrome may remain dimmed underneath a transient panel.
    public var transientControlsHidden: Bool
    public var pictureWaiting: Bool
    public var statusMounted: Bool
    public var powerMounted: Bool
    public var captureMounted: Bool
    public var captureHidden: Bool
    public var captureInteractive: Bool
    public var locked: Bool
    public var popupInteractive: Bool
    public var capturePresented: Bool
    public var panelsRaised: Bool
    public var recovering: Bool
    /// Keeps status telemetry mounted while excluding an occluded status slot from input and accessibility.
    public var statusInteractive: Bool

    public init(visible: Bool = true, interactive: Bool = true, dimmed: Bool = false,
        transientControlsHidden: Bool = false, pictureWaiting: Bool = false,
        statusMounted: Bool = true, powerMounted: Bool = true, captureMounted: Bool = true,
        captureHidden: Bool = false, captureInteractive: Bool = true, locked: Bool = false,
        popupInteractive: Bool = false, capturePresented: Bool = false, panelsRaised: Bool = false, recovering: Bool = false, statusInteractive: Bool = true) {
        self.visible = visible; self.interactive = interactive; self.dimmed = dimmed
        self.transientControlsHidden = transientControlsHidden; self.pictureWaiting = pictureWaiting
        self.statusMounted = statusMounted; self.powerMounted = powerMounted; self.captureMounted = captureMounted
        self.captureHidden = captureHidden; self.captureInteractive = captureInteractive; self.locked = locked
        self.popupInteractive = popupInteractive; self.capturePresented = capturePresented
        self.panelsRaised = panelsRaised; self.recovering = recovering
        self.statusInteractive = statusInteractive
    }
}
