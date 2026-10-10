import Foundation
import OpenCineDJI

/// One tap's four-write sequence over the actual native control source.
/// The host owns reticle/face presentation; this owner is independent of the settings FIFO.
@MainActor public final class DjiAppleTapFocus {
    private struct Authority {
        var generation: UInt64
        var binding: DjiAppleSettingsBinding
        var admission: DJICommandAdmission?
    }

    private let binding: () -> DjiAppleSettingsBinding
    private let sendPrepare: (Duml.Frame) -> UInt16
    private let request: @MainActor (Duml.Frame, String, Duration) async -> Bool
    private let sendAdmittedPrepare: ((Duml.Frame, DJICommandAdmission) -> DjiAppleCommandWrite)?
    private let admittedRequest:
        (@MainActor (Duml.Frame, String, Duration, DJICommandAdmission) async -> Bool)?
    private let prepared: (Duml.Frame, UInt16) -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding,
        sendPrepare: @escaping (Duml.Frame) -> UInt16,
        request: @escaping @MainActor (Duml.Frame, String, Duration) async -> Bool,
        prepared: @escaping (Duml.Frame, UInt16) -> Void = { _, _ in },
        sendAdmittedPrepare: ((Duml.Frame, DJICommandAdmission) -> DjiAppleCommandWrite)? = nil,
        admittedRequest:
            (@MainActor (Duml.Frame, String, Duration, DJICommandAdmission) async -> Bool)? = nil
    ) {
        self.binding = binding
        self.sendPrepare = sendPrepare
        self.request = request
        self.prepared = prepared
        self.sendAdmittedPrepare = sendAdmittedPrepare
        self.admittedRequest = admittedRequest
    }

    public func start(x: Float, y: Float) {
        start(x: x, y: y, suppliedAdmission: nil)
    }

    public func start(x: Float, y: Float, admission: DJICommandAdmission) {
        start(x: x, y: y, suppliedAdmission: admission)
    }

    private func start(x: Float, y: Float, suppliedAdmission admission: DJICommandAdmission?) {
        if let admission {
            guard admission.isCurrent, sendAdmittedPrepare != nil, admittedRequest != nil else {
                return
            }
        }
        generation &+= 1
        let authority = Authority(generation: generation, binding: binding(), admission: admission)
        let previous = task
        task = nil
        previous?.cancel()
        guard authority.binding.endpoint != nil, current(authority) else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(x: x, y: y, authority: authority)
            guard self.generation == authority.generation else { return }
            self.task = nil
        }
    }

    /// Retirement cancels only this sequence and never sends a camera command.
    public func retire() {
        generation &+= 1
        let previous = task
        task = nil
        previous?.cancel()
    }

    public func waitForPending() async { await task?.value }

    private func current(_ authority: Authority) -> Bool {
        generation == authority.generation && binding() == authority.binding
    }

    private func admitted(_ authority: Authority) -> Bool {
        !Task.isCancelled && current(authority) && (authority.admission?.isCurrent ?? true)
    }

    private func execute(x: Float, y: Float, authority: Authority) async {
        guard admitted(authority) else { return }
        // PREPARE has no reply wait: Mimo sends point before either ACK.
        let prepare = Commands.tapFocusPrepare()
        let sequence: UInt16
        if let admission = authority.admission {
            guard let sendAdmittedPrepare,
                case .queued(let queued) = sendAdmittedPrepare(prepare, admission)
            else { return }
            sequence = queued
        } else {
            sequence = sendPrepare(prepare)
        }
        guard admitted(authority) else { return }
        prepared(prepare, sequence)
        guard admitted(authority) else { return }
        let focused = await requestFrame(
            Commands.tapFocusPoint(x, y), name: "Focus region", authority: authority)
        guard admitted(authority), focused else { return }
        _ = await requestFrame(Commands.tapFocusLiveHint(), name: "AE hint", authority: authority)
        guard admitted(authority) else { return }
        _ = await requestFrame(Commands.tapFocusCommit(x, y), name: "Focus", authority: authority)
    }

    private func requestFrame(_ frame: Duml.Frame, name: String, authority: Authority) async -> Bool
    {
        if let admission = authority.admission {
            guard let admittedRequest else { return false }
            return await admittedRequest(frame, name, .milliseconds(800), admission)
        }
        return await request(frame, name, .milliseconds(800))
    }
}
