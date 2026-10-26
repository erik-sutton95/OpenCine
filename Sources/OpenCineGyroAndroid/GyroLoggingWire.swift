import Foundation
import OpenCineGyro

/// Owner-keyed Android bridge over the same per-take policy used by iOS.
public final class GyroLoggingWire: @unchecked Sendable {
    /// Process-local registry; every operation names its capture owner.
    public static let shared = GyroLoggingWire()
    private let lock = NSLock()
    private var sessions: [String: GyroTakeSession] = [:]
    private var recoveries: [String: GyroGCSVRecovery] = [:]

    /// Creates an isolated capture owner, without starting sensors or touching files.
    public func create(appName: String) -> String {
        lock.withLock {
            let owner = UUID().uuidString
            sessions[owner] = GyroTakeSession(appName: appName)
            return owner
        }
    }

    /// Decodes bounded little-endian `[timestamp, x, y, z]` Double batches.
    public func ingest(owner: String, bytes: [UInt8]) -> String? {
        guard bytes.count.isMultiple(of: 32), bytes.count <= 512 * 32 else { return nil }
        var samples: [GyroSample] = []
        for offset in stride(from: 0, to: bytes.count, by: 32) {
            let values = stride(from: offset, to: offset + 32, by: 8).map { start in
                var bits: UInt64 = 0
                for index in 0..<8 { bits |= UInt64(bytes[start + index]) << (index * 8) }
                return Double(bitPattern: bits)
            }
            samples.append(
                GyroSample(timestamp: values[0], x: values[1], y: values[2], z: values[3]))
        }
        return update(owner: owner) { $0.ingest(samples) }
    }

    /// Supplies a camera observation, not a command target or capture timestamp.
    /// An empty calibration string means no verified mount rotation for this take.
    public func observe(
        owner: String, recording: Bool, timestamp: Double,
        dateSeconds: Double, cameraLabel: String,
        calibrationJSON: String
    ) -> String? {
        guard timestamp.isFinite, dateSeconds.isFinite else { return nil }
        let calibration =
            calibrationJSON.isEmpty ? nil : GyroWireJSON.decodeCalibration(calibrationJSON)
        guard calibrationJSON.isEmpty || calibration != nil else { return nil }
        return update(owner: owner) {
            $0.observeRecording(
                recording, at: timestamp,
                date: Date(timeIntervalSince1970: dateSeconds), cameraLabel: cameraLabel,
                mountCalibration: calibration)
        }
    }

    /// Marks the first observed mount movement for every open take.
    public func mountMoved(owner: String, timestamp: Double) -> String? {
        guard timestamp.isFinite else { return nil }
        return update(owner: owner) { $0.observeMountMoved(at: timestamp) }
    }

    /// Advances postroll and sensor-stall checks on the platform sensor timebase.
    public func poll(owner: String, timestamp: Double) -> String? {
        guard timestamp.isFinite else { return nil }
        return update(owner: owner) { $0.poll(at: timestamp) }
    }

    /// Finalizes available samples honestly without changing camera recording.
    public func finish(owner: String, reason: String) -> String? {
        guard let reason = GyroLogTermination(rawValue: reason) else {
            return nil
        }
        return update(owner: owner) { $0.finish(reason: reason) }
    }

    /// Retires an owner after its platform has processed finalization updates.
    public func close(owner: String) { _ = lock.withLock { sessions.removeValue(forKey: owner) } }

    /// Starts streaming validation of an abandoned platform-owned partial file.
    public func recoveryCreate() -> String {
        lock.withLock {
            let owner = UUID().uuidString
            recoveries[owner] = GyroGCSVRecovery()
            return owner
        }
    }

    /// Returns the complete valid prefix length, or nil for an invalid header.
    public func recoveryAccept(owner: String, bytes: [UInt8]) -> Int64? {
        guard bytes.count <= 65_536 else { return nil }
        return lock.withLock {
            guard var recovery = recoveries[owner] else { return nil }
            do { try recovery.accept(Data(bytes)) } catch { return nil }
            recoveries[owner] = recovery
            return Int64(clamping: recovery.validByteCount)
        }
    }

    /// Summarizes recovered samples and retires the recovery owner on every exit.
    /// `Double.nan` means the store found no mount-moved mark for the take.
    public func recoveryFinish(
        owner: String, descriptorJSON: String, mountMovedOffset: Double
    ) -> String? {
        lock.withLock {
            guard let recovery = recoveries.removeValue(forKey: owner),
                let descriptor = GyroWireJSON.decodeDescriptor(descriptorJSON)
            else { return nil }
            let offset = mountMovedOffset.isNaN ? nil : mountMovedOffset
            guard
                let summary = try? recovery.finish(
                    descriptor: descriptor, mountMovedOffset: offset),
                let json = GyroWireJSON.loggingString(summary)
            else { return nil }
            return json
        }
    }

    private func update(
        owner: String,
        operation: (inout GyroTakeSession) -> [GyroLogUpdate]
    ) -> String? {
        lock.withLock {
            guard var session = sessions[owner] else { return nil }
            let updates = operation(&session)
            sessions[owner] = session
            return Self.reply(updates: updates, session: session)
        }
    }

    private static func reply(updates: [GyroLogUpdate], session: GyroTakeSession) -> String? {
        var objects: [[String: Any]] = []
        for update in updates {
            guard let object = updateObject(update) else { return nil }
            objects.append(object)
        }
        var reply: [String: Any] = [
            "updates": objects,
            "active": session.hasActiveTakes,
            "gapWarning": session.hasGapWarning,
            "finished": session.isFinished,
            "hasSamples": session.latestSampleTimestamp != nil,
        ]
        if let termination = session.termination {
            reply["termination"] = termination.rawValue
        }
        return GyroWireJSON.string(reply)
    }

    private static func updateObject(_ update: GyroLogUpdate) -> [String: Any]? {
        switch update {
        case .opened(let descriptor):
            guard
                let descriptorObject = GyroWireJSON.loggingObject(descriptor) as? [String: Any]
            else { return nil }
            return [
                "kind": "opened", "id": descriptor.id.uuidString,
                "descriptor": descriptorObject,
            ]
        case .appended(let id, let bytes):
            return [
                "kind": "appended", "id": id.uuidString,
                "data": bytes.base64EncodedString(),
            ]
        case .mountMoved(let id, let offsetSeconds):
            return [
                "kind": "mountMoved", "id": id.uuidString, "offsetSeconds": offsetSeconds,
            ]
        case .finished(let summary):
            guard let summaryObject = GyroWireJSON.loggingObject(summary) as? [String: Any] else {
                return nil
            }
            return [
                "kind": "finished", "id": summary.id.uuidString, "summary": summaryObject,
            ]
        }
    }
}
