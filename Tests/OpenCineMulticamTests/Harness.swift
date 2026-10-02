import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam

/// A camera that has reported once and, where it needs one, runs its own live view.
func reported(_ camera: FakeCameraSession) async -> FakeCameraSession {
    await camera.cameraReportsStatus()
    await camera.setLiveViewReady(true)
    return camera
}

/// The engine's input, gathered from the fakes the way an app gathers it from its sessions.
func state(
    _ cameras: [FakeCameraSession], pictures: [StreamID: PictureHealth] = [:],
    busy: Set<MonitorEntryID> = []
) async -> MulticamSnapshot {
    var snapshots: [CameraSnapshot] = []
    var now = MonotonicInstant.zero
    for camera in cameras {
        snapshots.append(await camera.current)
        now = max(now, await camera.now)
    }
    return MulticamSnapshot(cameras: snapshots, pictures: pictures, busy: busy, now: now)
}

func sessions(_ cameras: [FakeCameraSession]) -> [CameraSessionID: any CameraSession] {
    Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0 as any CameraSession) })
}

/// Moves every fake clock together.
func advance(_ cameras: [FakeCameraSession], by duration: Duration) async {
    for camera in cameras { await camera.advance(by: duration) }
}

/// An entry with picture, camera session and session telemetry.
func entry(
    _ name: String, _ camera: FakeCameraSession, picture: Bool = true,
    authority: ControlAuthority = .owner
) -> MonitorEntryDescriptor {
    MonitorEntryDescriptor(
        name: name, picture: picture ? FakePictureSource(label: name).descriptor : nil,
        cameraSession: camera.id, telemetry: .cameraSession, controlAuthority: authority)
}

func group(_ entries: [MonitorEntryDescriptor]) throws -> MulticamGroup {
    var group = MulticamGroup()
    for entry in entries { try group.add(entry) }
    return group
}

extension MulticamGroup {
    /// The entry with its camera session replaced, keeping its slot.
    mutating func replaceSession(of id: MonitorEntryID, with camera: FakeCameraSession) throws {
        var entry = self[id]!
        entry.cameraSession = camera.id
        try update(entry)
    }
}
