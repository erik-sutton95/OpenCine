import Foundation
import HarnessComposition
import HarnessEngine
import Insta360Protocol
import OpenCineCore
import OpenCineDJI
import OpenCineMedia
import OpenCineMulticam
import OpenCineNikon
import Testing

/// SIMULATED. MULTI-03 step 4: differing capabilities, unknown values, audio absence and clock
/// provenance across the three real sessions.
@MainActor
@Suite struct CapabilityTests {
    /// The controls a shared surface would lay out, from the capability snapshot alone: no
    /// integration ID, no brand branch.
    private func writable(_ snapshot: CameraSnapshot) -> Set<SettingKey> {
        Set(SettingKey.allCases.filter { snapshot.capabilities[$0]?.access == .readWrite })
    }

    @Test func eachSessionDescribesItsOwnControls() async throws {
        let rig = Rig()
        let state = await rig.state()
        let dji = try #require(state.cameras[rig.dji.id])
        let nikon = try #require(state.cameras[rig.nikon.id])
        let luna = try #require(state.cameras[rig.luna.id])

        #expect(writable(dji) == [.iso, .whiteBalance, .whiteBalanceTint, .recording])
        #expect(writable(nikon) == [.iso, .whiteBalance, .recording])
        #expect(writable(luna) == [.iso, .shutter, .whiteBalance, .focusMode, .recording])
        // Nikon offers the body's presets; DJI and Luna only Auto plus Kelvin.
        #expect(nikon.capabilities[.whiteBalance]?.domain?.choices.contains(.whiteBalance(.preset("Cloudy"))) == true)
        #expect(dji.capabilities[.whiteBalance]?.domain?.choices == [.whiteBalance(.auto)])
        // Luna's shutter is a native duration ladder: never an angle.
        let lunaShutter = luna.capabilities[.shutter]?.domain?.choices ?? []
        #expect(lunaShutter.contains(.shutter(.duration(Rational(1, 50)))))
        #expect(!lunaShutter.contains { if case .shutter(.angle) = $0 { true } else { false } })

        // A known-absent control is unsupported (F6): the Pocket's and Luna's fixed apertures.
        // The Nikon slice knows of no absent control, so its aperture is unknown, not unsupported.
        // Either way no iris is laid out and no value is invented.
        #expect(dji.capabilities.support(of: .aperture) == .unsupported)
        #expect(luna.capabilities.support(of: .aperture) == .unsupported)
        #expect(nikon.capabilities.support(of: .aperture) == .unknown)
        #expect(dji.capabilities.support(of: .zoom) == .unknown, "the Pocket has zoom, undescribed")
        for snapshot in [dji, nikon, luna] {
            #expect(snapshot.value(of: .aperture).isKnown == false)
            #expect(MonitorLayoutCapabilities(snapshot.capabilities).iris == false)
        }
        #expect(rig.dji.request(.set(.aperture(2))).stage == .rejected(.unsupported))
        #expect(nikon.capabilities.support(of: .whiteBalanceTint) == .unknown)
        #expect(dji.capabilities.support(of: .shutter) == .unknown)

        // An undescribed control is refused before it reaches any camera.
        let shutter = CameraCommandIntent.set(.shutter(.angle(180)))
        #expect(rig.dji.request(shutter).stage == .rejected(.supportUnknown))
        #expect(rig.nikon.request(shutter).stage == .rejected(.supportUnknown))
        #expect(await rig.luna.submit(CameraCommand(shutter, preconditions: CommandPreconditions(luna))).stage
            == .rejected(.outOfDomain))
        #expect(rig.djiPort.fired.isEmpty && rig.nikonDriver.queued.isEmpty && rig.lunaCamera.sent.isEmpty)
    }

    /// Nikon reports a native shutter angle; the Pocket reports `1/N` and its angle is derived.
    /// Neither session publishes shutter yet (F4); this pins the provenance each should carry.
    @Test func nativeAngleAndDerivedAngleKeepTheirProvenance() {
        var angle = Data(count: 4)
        angle.withUnsafeMutableBytes { $0.storeBytes(of: Int32(18_000).littleEndian, as: Int32.self) }
        let z = PTPCameraPropertySnapshot()
            .applying(property: .movieShutterMode, data: Data([2]))
            .applying(property: .movieShutterAngle, data: angle)
        let native = ProposedMappings.nikonShutter(z, at: .zero)
        #expect(native.value == .angle(180))
        #expect(native.origin == .cameraReported)

        var pocket = CameraStatus()
        pocket.shutterDenom = 50
        pocket.fps = 25
        let derived = ProposedMappings.djiShutterAngle(pocket)
        #expect(derived.value == .angle(180))
        #expect(derived.origin == .protocolDerived)

        // Unknown stays unknown, in the shared helper too (F4 fixed: no 180 degrees, no 24 fps).
        pocket.shutterDenom = -1
        #expect(ShutterAngle.degrees(denom: -1, fps: 25) == nil)
        #expect(ShutterAngle.degrees(denom: 50, fps: 0) == nil)
        #expect(ProposedMappings.djiShutterAngle(pocket).isKnown == false)
        pocket.shutterDenom = 50
        pocket.fps = 0
        #expect(ProposedMappings.djiShutterAngle(pocket).isKnown == false)
    }

    @Test func unknownValuesStayUnknown() async throws {
        let rig = Rig()
        rig.djiPort.status.batteryPercent = -1
        rig.djiPort.status.recordingReported = false
        rig.nikonDriver.nikonControlFacts.recording = nil
        rig.nikon.refresh()
        rig.lunaCamera.captureState = nil  // no capture reply at all
        let luna = rig.lunaCamera.connectedSession(settle: .milliseconds(300))
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", luna)]
        let g = try group(entries)
        let state = await MulticamSnapshot.gather([rig.dji, rig.nikon, luna], now: .zero)

        for snapshot in state.cameras.values {
            #expect(snapshot.recording.isKnown == false)
            #expect(snapshot.storage.isKnown == false, "no session here reports storage")
        }
        #expect(state.cameras[rig.dji.id]?.power.battery.isKnown == false)
        #expect(state.cameras[luna.id]?.power.battery.isKnown == false)
        #expect(g.summary(at: state, telemetryMaxAge: .seconds(3600)).camerasRecordingUnknown == 3)

        // Unknown recording is never treated as idle: no camera gets a start.
        let plan = RecordPlan.make(.start, policy: .eligibleSubset, entries: entries.map(\.id), in: g, at: state)
        #expect(plan.targets.isEmpty)
        #expect(plan.exclusions.map(\.reason) == Array(repeating: .rejected(.recordingStateUnknown), count: 3))
    }

    /// Audio: the DJI session publishes level support for the body (SHELL-01), but before the
    /// camera reports, the levels are unknown, never measured silence (F3).
    @Test func audioAbsenceNeverFabricatesMeters() async throws {
        let rig = Rig()
        let snapshot = try #require(await rig.dji.currentSnapshot())
        #expect(snapshot.capabilities.audioLevels == .supported)
        #expect(snapshot.audioLevels == .unknown, "no report is unknown, never measured silence")
        #expect(CameraStatus().audioMeters == nil)
        #expect(MonitorLayoutCapabilities(snapshot.capabilities).audio, "a meter section, empty until reported")
    }

    /// Plan 8.3: the Luna time is the phone's own clock carried forward, so it can never establish
    /// a clock relationship; a Nikon readback can, within its tolerance. Neither is synchronized
    /// recording, and the group report has no way to say so.
    @Test func clockDerivedTimeNeverClaimsSync() async throws {
        let rig = Rig()
        let set = try ProposedMappings.lunaClockSet(
            unixSeconds: 1_790_000_000, timeZoneSeconds: 7_200, zone: "Europe/Stockholm")
        #expect(set.request.command == .setOptions)
        #expect(set.offset.origin == .clockDerived)
        #expect(ClockRelationship(set.offset) == .unknown)

        let phone = CameraClockSync.WallClock(year: 2026, month: 10, day: 2, hour: 1, minute: 0, second: 0)
        let nikonClock = ProposedMappings.nikonClockOffset(
            cameraPayload: CameraClockSync.encode(phone), phoneNow: phone)
        #expect(ClockRelationship(nikonClock) == .measured(uncertaintySeconds: 6))

        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        let state = await rig.state(entries)
        let result = await (try RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: state)
            .submit(in: g, at: state, sessions: rig.map)).finished(sessions: rig.map)
        let report = GroupSyncReport(
            result, cameraClocks: [rig.nikon.id: nikonClock, rig.luna.id: set.offset])
        #expect(report.confirmed.count == 3)
        #expect(
            report.clocks == [
                rig.dji.id: .unknown, rig.nikon.id: .measured(uncertaintySeconds: 6),
                rig.luna.id: .unknown,
            ])
        let levels = Mirror(reflecting: report).children.compactMap(\.label)
        #expect(levels == ["confirmed", "unconfirmed", "clocks"], "no synchronized flag exists")

        // The Luna session itself never publishes a clock-derived value as a camera report.
        let luna = try #require(state.cameras[rig.luna.id])
        let origins = luna.settings.values.map(\.origin) + [luna.mode.origin, luna.recording.origin]
        #expect(!origins.contains(.clockDerived))
    }
}
