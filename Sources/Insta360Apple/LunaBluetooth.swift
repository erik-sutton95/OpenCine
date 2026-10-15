import CoreBluetooth
import Foundation
import Insta360Protocol
import OpenCineCore

@MainActor
// CoreBluetooth delegates are explicitly delivered on DispatchQueue.main. The
// preconcurrency conformance preserves that framework contract across SDK versions.
final class LunaBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    /// The operator-facing app name in the Bluetooth permission copy.
    private let appName: String
    var onCamera: ((MonitorCamera) -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var centralWasCreated = false
    private lazy var central: CBCentralManager = {
        centralWasCreated = true
        return CBCentralManager(delegate: self, queue: .main)
    }()
    private var epoch = 0
    private var disconnecting = Set<UUID>()
    private var powerOperation: UUID?
    private var readyOperation: UUID?
    private var writeOperation: UUID?
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// When each camera last advertised: one silent for longer is off or out of range.
    private var advertisedAt: [UUID: ContinuousClock.Instant] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var powerWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private let service = CBUUID(string: LunaProtocol.bluetoothServiceUUID)
    private let writeID = CBUUID(string: LunaProtocol.bluetoothWriteUUID)
    private let notifyID = CBUUID(string: LunaProtocol.bluetoothNotifyUUID)
    var commandSource: LunaNativeCommandSource {
        .init(transport: self, epoch: epoch, endpoint: peripheral, member: writeCharacteristic)
    }

    init(appName: String) {
        self.appName = appName
    }

    func startScan() async throws {
        try await waitForPower()
        central.scanForPeripherals(
            withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    /// True when this launch has seen the camera advertise (so BLE can reach it now).
    func hasSeen(_ id: UUID) -> Bool { peripherals[id] != nil }

    func stopScan() {
        guard centralWasCreated else { return }
        central.stopScan()
    }
    private func waitForPower() async throws {
        try Task.checkCancellation()
        if central.state == .poweredOn { return }
        if let failure = powerFailure(central.state) { throw failure }
        let token = epoch
        let operation = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                powerOperation = operation
                powerWaiter = continuation
                setDeadline(
                    seconds: 15,
                    failure: .luna(
                        .radioOff(.bluetooth), "bluetooth.unavailable",
                        "Bluetooth is not ready yet. Try again in a moment."))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == token, self.powerOperation == operation else {
                    return
                }
                self.failPending(CancellationError())
            }
        }
    }
    func connect(id: UUID) async throws {
        try await waitForPower()
        let found = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let found else {
            throw ConnectionFailure.luna(
                .notFound, "bluetooth.not-nearby",
                "The camera is no longer nearby. Scan again with the camera powered on.",
                phase: .link)
        }
        // cancelPeripheralConnection completes asynchronously. Do not reuse this object
        // until its old didDisconnect/didFail callback has been consumed.
        let deadline = Date().addingTimeInterval(12)
        // A cancelled link that iOS already reports disconnected owes no further callback.
        if found.state == .disconnected { disconnecting.remove(id) }
        while disconnecting.contains(id), Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
            if found.state == .disconnected { disconnecting.remove(id) }
        }
        guard !disconnecting.contains(id) else {
            throw ConnectionFailure.luna(
                .other, "bluetooth.closing",
                "The previous camera Bluetooth connection is still closing. Try connecting again.",
                phase: .link)
        }
        try Task.checkCancellation()
        let advertisedRecently = advertisedAt[id].map { ContinuousClock.now - $0 < .seconds(30) } ?? false
        let token = epoch
        let operation = UUID()
        peripheral = found
        found.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                readyOperation = operation
                readyWaiter = continuation
                setDeadline(
                    seconds: 25,
                    failure: Self.connectTimeoutFailure(advertisedRecently: advertisedRecently))
                central.connect(found)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == token, self.readyOperation == operation else {
                    return
                }
                self.disconnect()
            }
        }
        central.stopScan()
    }
    func write(_ data: Data) async throws {
        try await write(data, firstDispatch: nil, didDispatch: nil)
    }
    func write(
        _ data: Data, admission: LunaCommandAdmission, source: LunaNativeCommandSource,
        didDispatch: @escaping LunaCommandDidDispatch
    ) async throws {
        try admission.requireCurrent()
        guard source.member != nil, source.admits(commandSource) else {
            throw LunaCommandAdmissionError.expired
        }
        try await write(
            data, firstDispatch: .init(admission: admission, source: source),
            didDispatch: didDispatch)
    }
    private func write(
        _ data: Data, firstDispatch supplied: LunaCommandFirstDispatch?,
        didDispatch: LunaCommandDidDispatch?
    ) async throws {
        guard let peripheral, let characteristic = writeCharacteristic,
            peripheral.state == .connected
        else {
            throw ConnectionFailure.lunaBluetoothClosed
        }
        let size = min(
            LunaProtocol.bluetoothWriteChunkSize,
            peripheral.maximumWriteValueLength(for: .withResponse))
        guard size > 0 else {
            throw ConnectionFailure.luna(
                .other, "bluetooth.write-size",
                "The camera did not provide a Bluetooth write size.", phase: .link)
        }
        var offset = 0
        var firstDispatch = supplied
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(data.count, offset + size)
            let chunk = data.subdata(in: offset..<end)
            let token = epoch
            let operation = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let write = {
                        self.writeOperation = operation
                        self.writeWaiter = continuation
                        self.setDeadline(
                            seconds: 10,
                            failure: .luna(
                                .timedOut, "bluetooth.write-timeout",
                                "The camera did not acknowledge a Bluetooth command.",
                                phase: .link))
                        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                    }
                    if var first = firstDispatch {
                        do {
                            guard let didDispatch else { throw LunaCommandAdmissionError.expired }
                            try first.perform(
                                current: { self.commandSource }, native: write, didDispatch: didDispatch)
                            firstDispatch = first
                        } catch { continuation.resume(throwing: error) }
                    } else {
                        write()
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == token, self.writeOperation == operation else {
                        return
                    }
                    self.disconnect()
                }
            }
            offset = end
        }
    }
    func disconnect() {
        epoch += 1
        guard centralWasCreated else {
            failPending(CancellationError())
            return
        }
        central.stopScan()
        let old = peripheral
        peripheral = nil
        writeCharacteristic = nil
        if let old, old.state != .disconnected {
            old.delegate = nil
            if Self.awaitsCloseCallback(old.state) { disconnecting.insert(old.identifier) }
            central.cancelPeripheralConnection(old)
        }
        failPending(CancellationError())
    }
    /// Whether cancelling a peripheral in `state` is followed by a didDisconnect/didFailToConnect
    /// callback that must be consumed before the object is reused. A connect still pending
    /// (`.connecting`) is cancelled silently: waiting for a callback there marked the camera
    /// "still closing" for the rest of the launch (device cell 7d).
    nonisolated static func awaitsCloseCallback(_ state: CBPeripheralState) -> Bool {
        state == .connected || state == .disconnecting
    }

    /// The failure when the camera never completed its Bluetooth connection in time. A camera
    /// heard advertising lately is there but held; a silent one is off or out of range.
    nonisolated static func connectTimeoutFailure(advertisedRecently: Bool) -> ConnectionFailure {
        guard advertisedRecently else {
            return .luna(
                .notFound, "bluetooth.camera-missing",
                "The camera did not answer. Make sure it is turned on and nearby, then try again.",
                phase: .link)
        }
        return .luna(
            .timedOut, "bluetooth.connect-timeout",
            "The camera did not complete its Bluetooth connection. Close the camera app on other devices and try again.",
            phase: .link)
    }

    private func setDeadline(seconds: Double, failure: ConnectionFailure) {
        deadline?.cancel()
        let token = epoch
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.epoch == token else { return }
            self?.failPending(failure)
        }
    }
    private func failPending(_ error: Error) {
        deadline?.cancel()
        deadline = nil
        powerOperation = nil
        readyOperation = nil
        writeOperation = nil
        let power = powerWaiter
        powerWaiter = nil
        power?.resume(throwing: error)
        let ready = readyWaiter
        readyWaiter = nil
        ready?.resume(throwing: error)
        let write = writeWaiter
        writeWaiter = nil
        write?.resume(throwing: error)
    }
    private func powerFailure(_ state: CBManagerState) -> ConnectionFailure? {
        switch state {
        // Only the permission needs Settings; off and not ready ask to try again.
        case .poweredOff:
            .luna(
                .radioOff(.bluetooth), "bluetooth.off",
                "Bluetooth is off. Turn it on in Control Center or Settings, then try again.")
        case .unauthorized:
            .luna(
                .permission(.bluetooth), "bluetooth.denied",
                "\(appName) needs Bluetooth access to find the camera. Open Settings, turn on Bluetooth for \(appName), then try again.",
                actions: [.openSettings, .retry])
        case .unsupported:
            .luna(
                .unsupported, "bluetooth.unsupported",
                "Bluetooth camera discovery is unavailable on this device.")
        default: nil
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if let waiter = powerWaiter {
                deadline?.cancel()
                powerWaiter = nil
                powerOperation = nil
                waiter.resume()
            }
        } else if let failure = powerFailure(central.state) {
            failPending(failure)
            if peripheral != nil { onDisconnect?(failure.message) }
        }
    }
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        advertisedAt[peripheral.identifier] = .now
        let name =
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            ?? LunaProtocol.model
        onCamera?(
            MonitorCamera(
                id: peripheral.identifier, name: name, model: LunaProtocol.model,
                capabilities: [.liveVideo]))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([service])
    }
    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        if disconnecting.remove(peripheral.identifier) != nil { return }
        guard peripheral === self.peripheral else { return }
        failPending(
            error
                ?? ConnectionFailure.luna(
                    .linkLost, "bluetooth.connect-failed",
                    "The camera could not connect over Bluetooth.", phase: .link))
    }
    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        if disconnecting.remove(peripheral.identifier) != nil { return }
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil
        writeCharacteristic = nil
        failPending(ConnectionFailure.lunaBluetoothClosed)
        onDisconnect?(ConnectionFailure.lunaBluetoothClosed.message)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error {
            failPending(error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == self.service }) else {
            failPending(
                ConnectionFailure.luna(
                    .unsupported, "bluetooth.service-missing",
                    "This camera did not expose the supported Insta360 Bluetooth service.",
                    phase: .link))
            return
        }
        peripheral.discoverCharacteristics([writeID, notifyID], for: service)
    }
    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        if let error {
            failPending(error)
            return
        }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == writeID })
        guard writeCharacteristic != nil,
            let notify = service.characteristics?.first(where: { $0.uuid == notifyID })
        else {
            failPending(
                ConnectionFailure.luna(
                    .unsupported, "bluetooth.channels-missing",
                    "The camera's Bluetooth command channels were not found.",
                    phase: .link))
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic.uuid == notifyID else { return }
        if let error {
            failPending(error)
            return
        }
        guard characteristic.isNotifying else {
            failPending(
                ConnectionFailure.luna(
                    .other, "bluetooth.notify-failed",
                    "Camera Bluetooth notifications could not be enabled.",
                    phase: .link))
            return
        }
        deadline?.cancel()
        let waiter = readyWaiter
        readyWaiter = nil
        readyOperation = nil
        waiter?.resume()
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic.uuid == notifyID else { return }
        if let error {
            failPending(error)
            return
        }
        if let data = characteristic.value { onData?(data) }
    }
    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic.uuid == writeID else { return }
        deadline?.cancel()
        let waiter = writeWaiter
        writeWaiter = nil
        writeOperation = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }
}
