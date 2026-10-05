import Foundation
import OpenCineDJI

/// One tap's four-write sequence over the actual native control source.
/// The host owns reticle/face presentation; this owner is independent of the settings FIFO.
@MainActor public final class DjiAppleTapFocus {
    private struct Authority {
        var generation: UInt64
        var binding: DjiAppleSettingsBinding
    }

    private let binding: () -> DjiAppleSettingsBinding
    private let sendPrepare: (Duml.Frame) -> UInt16
    private let request: @MainActor (Duml.Frame, String, Duration) async -> Bool
    private let prepared: (Duml.Frame, UInt16) -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding,
        sendPrepare: @escaping (Duml.Frame) -> UInt16,
        request: @escaping @MainActor (Duml.Frame, String, Duration) async -> Bool,
        prepared: @escaping (Duml.Frame, UInt16) -> Void = { _, _ in }
    ) {
        self.binding = binding
        self.sendPrepare = sendPrepare
        self.request = request
        self.prepared = prepared
    }

    public func start(x: Float, y: Float) {
        generation &+= 1
        let authority = Authority(generation: generation, binding: binding())
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

    private func current(_ authority: Authority) -> Bool {
        generation == authority.generation && binding() == authority.binding
    }

    private func admitted(_ authority: Authority) -> Bool {
        !Task.isCancelled && current(authority)
    }

    private func execute(x: Float, y: Float, authority: Authority) async {
        guard admitted(authority) else { return }
        // PREPARE has no reply wait: Mimo sends point before either ACK.
        let prepare = Commands.tapFocusPrepare()
        let sequence = sendPrepare(prepare)
        guard admitted(authority) else { return }
        prepared(prepare, sequence)
        guard admitted(authority) else { return }
        let focused = await request(
            Commands.tapFocusPoint(x, y), "Focus region", .milliseconds(800))
        guard admitted(authority), focused else { return }
        _ = await request(Commands.tapFocusLiveHint(), "AE hint", .milliseconds(800))
        guard admitted(authority) else { return }
        _ = await request(Commands.tapFocusCommit(x, y), "Focus", .milliseconds(800))
    }
}
