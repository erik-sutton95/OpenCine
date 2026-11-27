#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import SwiftUI

/// The scroll wheel on the capture strip in a Mac window (spec
/// 2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md). A readout whose hold opens a drum
/// is marked while the pointer rests on it, and the wheel steps it through the drum's values; with
/// a camera panel open, only that panel's setting takes the wheel, over the panel or its readout
/// (`wheelTarget`). Writes go through the readout's own setter, coalesced (`MonitorWheelDial`).
/// The format, colour and mode chips and the supplementary readouts never take the wheel. On an
/// iPhone or iPad it adds nothing. Attach it to the monitor's root view.
public struct MonitorOperatorCaptureWheel<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable>: ViewModifier {
    private let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    private let control: MonitorControlModel
    private let state: MonitorOperatorCaptureState<Key, NativeIdentity>
    private let enabled: Bool
    private let commandEnabled: Bool
    private let currentSource: () -> Bool

    public init(inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>, control: MonitorControlModel,
        state: MonitorOperatorCaptureState<Key, NativeIdentity>, enabled: Bool, commandEnabled: Bool,
        currentSource: @escaping () -> Bool) {
        self.inputs = inputs; self.control = control; self.state = state
        self.enabled = enabled; self.commandEnabled = commandEnabled; self.currentSource = currentSource
    }

    public func body(content: Content) -> some View {
        // Hover on the readouts and the panel picks the target; the window only delivers the wheel.
        content.monitorPointerWheel(onHover: { _ in }, onScroll: { event in scroll(event) })
    }

    private func scroll(_ event: MonitorPointerScroll) {
        guard let key = inputs.wheelTarget(state: state, enabled: enabled, commandEnabled: commandEnabled,
                currentSource: currentSource),
            let snapshot = inputs.wheelSnapshot(key),
            let turn = state.wheelDial.turn(key: key, options: snapshot.options, reported: snapshot.originIndex,
                dx: event.dx, dy: event.dy, device: event.device, at: ProcessInfo.processInfo.systemUptime)
        else { return }
        if turn.write { send(key, turn.value) }
        scheduleFlush()
    }

    /// Sends `value` through the readout's own setter: its common field, else its native commit.
    private func send(_ key: Key, _ value: String) {
        guard enabled, commandEnabled, currentSource(),
            let readout = inputs.readouts.first(where: { $0.id == key }) else { return }
        if let field = readout.field {
            // The field the readout showed is still the one the camera edits.
            guard field.isEditable, control.captureField(field.key)?.editor == field.editor,
                let choice = field.choices.first(where: { $0.label == value }) else { return }
            control.commit(choice, from: field)
        } else if let native = inputs.nativeQuick(key), native.enabled {
            inputs.nativeCommit(key, native.identity, value)
        }
    }

    /// Sends a held value once its turn comes.
    private func scheduleFlush() {
        state.wheelFlush?.cancel()
        guard let due = state.wheelDial.nextDue else {
            state.wheelFlush = nil
            return
        }
        let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
        let wheel = self
        state.wheelFlush = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            wheel.flush()
        }
    }

    private func flush() {
        for (key, value) in state.wheelDial.due(at: ProcessInfo.processInfo.systemUptime) { send(key, value) }
        scheduleFlush()
    }
}
extension MonitorOperatorCaptureInputs {
    /// The setting the scroll wheel changes now: the readout the pointer rests on (hover, which
    /// follows what is on top), when its hold opens a drum and the strip admits a change; with a
    /// camera panel open, only that panel's setting, over the panel or its readout.
    func wheelTarget(state: MonitorOperatorCaptureState<Key, NativeIdentity>, enabled: Bool,
        commandEnabled: Bool, currentSource: () -> Bool) -> Key? {
        guard enabled, commandEnabled, currentSource(), state.preview == nil, state.ownership.owner == nil
        else { return nil }
        if let panel {
            let over = state.pointerOnPanel || state.wheelHover == panel.key
            return over && wheelSnapshot(panel.key) != nil ? panel.key : nil
        }
        guard commitAdmission(), presentationOwner?() == nil, let key = state.wheelHover,
            wheelSnapshot(key) != nil else { return nil }
        return key
    }

    /// The drum the readout's hold would open: its values and where the reported value sits.
    func wheelSnapshot(_ key: Key) -> MonitorReadoutSnapshot? {
        guard let readout = readouts.first(where: { $0.id == key }), readout.quickEnabled,
            readout.action == nil else { return nil }
        if let field = readout.field { return field.isEditable ? readout.fieldSnapshot : nil }
        return nativeQuick(key).flatMap { $0.enabled ? $0.snapshot : nil }
    }
}
#endif
