import AppKit
import Foundation
import Observation
import OpenCineDesktopKit

/// One running camera module: its process and its private channel. The channel is a socket pair on
/// the child's standard input, so anything the module prints cannot corrupt it.
@MainActor @Observable
final class ModuleProcess: Identifiable {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case crashed
    }

    nonisolated let id: String
    let module: InstalledModule
    let slot: VirtualCameraSlot
    private(set) var phase = Phase.stopped
    private(set) var status = ModuleStatus.idle
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var channel: FileHandle?
    @ObservationIgnored private var inbound = Data()
    @ObservationIgnored private var expectingExit = false
    @ObservationIgnored private var restartAfterExit = false
    /// Every message from the module, and `nil` once its process has ended. The dock's window
    /// coordinator decides what each one means for the windows.
    @ObservationIgnored var onEvent: (ModuleProcess, ModuleMessage?) -> Void = { _, _ in }

    init(module: InstalledModule, slot: VirtualCameraSlot) {
        id = module.manifest.id
        self.module = module
        self.slot = slot
    }

    func start() {
        guard phase != .running, phase != .starting else { return }
        guard let executable = Bundle(url: module.bundleURL)?.executableURL else {
            phase = .crashed
            status = .failed("The module's app bundle is damaged.")
            return
        }
        // A module left running by a dock that crashed would hold this input's sink.
        if let bundleID = Bundle(url: module.bundleURL)?.bundleIdentifier {
            for stray in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                stray.forceTerminate()
            }
        }
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            phase = .crashed
            status = .failed("Could not open the module's channel.")
            return
        }
        // Writing to a module that has just gone must fail, not take the dock down with SIGPIPE.
        var noSignal: Int32 = 1
        setsockopt(
            sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let child = Process()
        child.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCINE_MODULE_ID"] = id
        environment["OPENCINE_MODULE_SLOT"] = String(slot.number)
        child.environment = environment
        child.standardInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        if let log = Self.logFile(for: id) {
            child.standardOutput = log
            child.standardError = log
        }
        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.exited(status: status) }
        }
        let handle = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else {
                file.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.received(data) }
        }
        channel = handle
        inbound = Data()
        expectingExit = false
        do {
            try child.run()
            process = child
            phase = .starting
            status = .idle
        } catch {
            phase = .crashed
            status = .failed(error.localizedDescription)
        }
    }

    func send(_ message: DockMessage) {
        if case .quit = message { expectingExit = true }
        guard let channel, let data = try? LengthPrefixedJSON.encode(message) else { return }
        try? channel.write(contentsOf: data)
    }

    /// Ends the module, escalating if it does not leave on its own.
    func quit() {
        guard let process, process.isRunning else { return }
        send(.quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    var processIdentifier: pid_t? { process?.processIdentifier }
    var isProcessRunning: Bool { process?.isRunning == true }

    func forceStop() {
        if process?.isRunning == true { process?.terminate() }
    }

    /// Stops a running module and starts it again once it has gone.
    func restartRunning() {
        guard isProcessRunning else { return }
        restartAfterExit = true
        quit()
    }

    var activate: () -> Void {
        { [process] in
            guard let process else { return }
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
        }
    }

    private func received(_ data: Data) {
        inbound.append(data)
        guard let messages: [ModuleMessage] = try? LengthPrefixedJSON.decodeAll(&inbound) else {
            inbound = Data()
            return
        }
        for message in messages {
            switch message {
            case .ready: phase = .running
            case .status(let next): status = next
            case .selectTab, .windowFrame, .shown, .closeRequested: break
            }
            onEvent(self, message)
        }
    }

    private func exited(status code: Int32) {
        process = nil
        channel?.readabilityHandler = nil
        channel = nil
        if restartAfterExit {
            restartAfterExit = false
            phase = .stopped
            onEvent(self, nil)
            start()
        } else if expectingExit {
            phase = .stopped
            onEvent(self, nil)
        } else {
            phase = .crashed
            status = .failed("Stopped unexpectedly (\(code)). Its input shows a slate until restart.")
            onEvent(self, nil)
        }
    }

    private static func logFile(for id: String) -> FileHandle? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenCine", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }
}
