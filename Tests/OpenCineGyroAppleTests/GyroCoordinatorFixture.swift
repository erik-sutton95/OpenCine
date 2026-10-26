#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing
import UIKit

@testable import OpenCineGyroApple

/// The manual clock every coordinator test reads through `now`.
@MainActor final class GyroTestClock {
    var time: Double = 10
}

/// A scripted motion driver: raw samples go into the coordinator's buffer and device-motion
/// readings are pushed by the test.
@MainActor final class FakeGyroMotionDriver: GyroMotionDriving {
    var buffer: GyroSampleBuffer?
    var starts = 0
    var unavailable = false
    private(set) var motionConsumers: [UUID: (GyroDriftReading) -> Void] = [:]

    func startGyro(into buffer: GyroSampleBuffer) throws {
        if unavailable { throw PhoneMotionError.unavailable }
        starts += 1
        self.buffer = buffer
    }

    func stopGyro() { buffer = nil }

    func startMotion(_ receive: @escaping (GyroDriftReading) -> Void) throws -> UUID {
        if unavailable { throw PhoneMotionError.motionUnavailable }
        let id = UUID()
        motionConsumers[id] = receive
        return id
    }

    func stopMotion(_ id: UUID) { motionConsumers.removeValue(forKey: id) }

    func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID { UUID() }

    func stopLevel(_ id: UUID) {}

    /// Delivers one device-motion reading to every consumer.
    func push(_ reading: GyroDriftReading) {
        for receive in Array(motionConsumers.values) { receive(reading) }
    }
}

/// An in-memory key-value store shared across coordinator instances to model relaunches.
final class MemoryGyroKeyValueStore: GyroKeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func setData(_ data: Data?, forKey key: String) { values[key] = data }
}

/// One test's collaborators: fake driver, fake camera, manual clock, temporary log directory.
@MainActor struct GyroCoordinatorFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gyro-tests-\(UUID().uuidString)")
    let driver = FakeGyroMotionDriver()
    let clock = GyroTestClock()
    let keyValues = MemoryGyroKeyValueStore()
    let camera: FakeGyroCameraAdapter
    let keys = GyroPreferenceKeys.namespaced("test.gyro.")

    init(camera: FakeGyroCameraAdapter = FakeGyroCameraAdapter()) {
        self.camera = camera
    }

    var host: GyroHostConfiguration {
        GyroHostConfiguration(appName: "Test app", logDirectory: directory, preferenceKeys: keys)
    }

    var preferences: GyroPreferences {
        GyroPreferences(store: keyValues, keys: keys, legacy: nil)
    }

    /// A coordinator on the manual clock with the fake camera attached and the monitor showing.
    func coordinator(
        store: (any GyroLogStoring)? = nil, attach: Bool = true, hostEligible: Bool = true
    ) -> GyroCaptureCoordinator {
        let coordinator = GyroCaptureCoordinator(
            host: host, driver: driver, store: store ?? GyroLogStore(directory: directory),
            keyValueStore: keyValues, now: { [clock] in clock.time }, automaticProcessing: false)
        coordinator.beginBackgroundTask = { _ in UIBackgroundTaskIdentifier(rawValue: 42) }
        coordinator.endBackgroundTaskHandler = { _ in }
        if attach { coordinator.attach(camera) }
        coordinator.setHostEligible(hostEligible)
        return coordinator
    }

    /// Connects the fake camera with stabilization already off.
    func connect(recording: Bool? = false, videoMode: Bool? = true) {
        camera.connect(
            stabilization: .init(values: ["ibis": "OFF"], lensHasVRSwitch: nil),
            recording: recording, videoMode: videoMode, at: clock.time)
    }

    /// Reports REC at the current clock time.
    func record(_ recording: Bool) {
        camera.send(.recording(recording, at: clock.time))
    }

    /// Queues 100 Hz samples from `start` through `end` and moves the clock to `end`.
    func feed(from start: Double, through end: Double) {
        for index in 0...Int(((end - start) * 100).rounded()) {
            driver.buffer?.append(
                GyroSample(timestamp: start + Double(index) / 100, x: 1, y: 2, z: 3))
        }
        clock.time = end
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A store whose every write fails, to prove the coordinator aborts file ownership.
actor FailingGyroStore: GyroLogStoring {
    var aborted = false
    func load() -> GyroLogRecoveryResult { .init(entries: [], warning: nil) }
    func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func abort() -> GyroLogRecoveryResult {
        aborted = true
        return .init(entries: [], warning: nil)
    }
    func share(_ ids: [UUID]) throws -> [URL] { throw GyroStoreError.missing }
    func delete(_ id: UUID) -> [GyroLogEntry] { [] }
}
#endif
