#if os(iOS)
import MonitorUI
import OpenCineAppKit
import SwiftUI
import Testing
import UIKit

@testable import OpenCineAppKitApple

/// A2-32: the remote shutter and auto-rotate are separate optional capabilities, and the shared
/// owner turns the remote shutter on with one typed declaration.
@MainActor @Suite struct MonitorRemoteShutterTests {
    @Test func eachInputCapabilityIsDeclaredOnItsOwn() {
        var stored = false
        let choice = Binding(get: { stored }, set: { stored = $0 })
        let shutter = MonitorSettingsInputSource(remoteShutter: .volumeButtons(enabled: choice))
        #expect(shutter.autoRotate == nil, "a remote shutter needs no rotation binding")
        #expect(shutter.remoteShutter?.title == MonitorRemoteShutter.title)
        #expect(shutter.remoteShutter?.help == MonitorRemoteShutter.help)
        shutter.remoteShutter?.enabled.wrappedValue = true
        #expect(stored)

        let rotation = MonitorSettingsInputSource(autoRotate: .init(enabled: choice, help: "Upright"))
        #expect(rotation.remoteShutter == nil, "auto-rotate needs no remote shutter")
        #expect(rotation.autoRotate?.help == "Upright")
        #expect(MonitorSettingsInputSource().remoteShutter == nil && MonitorSettingsInputSource().autoRotate == nil)
    }

    @Test func theSystemVolumeSliderIsFoundInsideNestedViews() {
        let volumeView = UIView()
        let container = UIView()
        let slider = UISlider()
        container.addSubview(slider)
        volumeView.addSubview(container)
        #expect(MonitorRemoteShutter.firstSlider(in: volumeView) === slider)
    }

    @Test func routeSuppressionRejectsADelayedVolumeThatNoLongerMatches() async throws {
        let owner = MonitorRemoteShutter(subsystem: "SIMULATED")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let slider = RecordingSlider()
        owner.volumeWriter.hostWindow = { window }
        owner.volumeWriter.makeView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.addSubview(slider)
            return view
        }
        #expect(owner.update(enabled: true, monitorPresented: true, liveViewFront: true))
        owner.volumeWriter.cancel()
        owner.presses.reanchor(volume: 0.25)
        owner.liveVolume = { 0.5 }
        owner.suppressVolumeEventsUntil = CFAbsoluteTimeGetCurrent() + 10

        owner.adjudicateVolumeChange(0.5625, source: "SIMULATED stale")
        try await Task.sleep(for: .milliseconds(300))
        #expect(slider.writes.isEmpty, "a stale report never re-pins the anchor")

        owner.adjudicateVolumeChange(0.5, source: "SIMULATED current")
        try await Self.waitUntil { slider.writes == [0.25] }
        owner.stop()
    }

    @Test func aNewOwnerIsIdleUntilTheHostArmsIt() {
        let owner = MonitorRemoteShutter(subsystem: "SIMULATED")
        #expect(!owner.isActive)
        owner.stop()
        #expect(!owner.isActive)
        #expect(!owner.update(enabled: false, monitorPresented: true, liveViewFront: true))
        #expect(!owner.isActive, "a disabled shutter never takes the audio session")
    }

    /// The idle regression: the writer installs its volume view only for a write and releases it
    /// a hold later, so an armed shutter at rest leaves nothing in the window that keeps the app
    /// from idling.
    @Test func aWriteLeasesTheVolumeViewAndReleasesItAfterTheHold() async throws {
        let (writer, window, slider) = Self.writer()
        var written: [Float] = []
        writer.onWritten = { written.append($0) }
        #expect(writer.view == nil && window.subviews.isEmpty, "nothing is installed before a write")
        #expect(!writer.writeNow(0.5), "no slider is in hand without a lease")

        writer.write(0.25)
        writer.write(0.75)
        let view = try #require(writer.view)
        #expect(view.superview === window)
        try await Self.waitUntil { written == [0.75] }
        #expect(slider.writes == [0.75], "the newest request is the one written")
        #expect(writer.view === view, "held for the write's echo")
        #expect(writer.writeNow(0.5), "a slider is in hand while the lease is held")

        try await Self.waitUntil(seconds: MonitorRemoteShutterVolumeLease.hold + 2) { writer.view == nil }
        #expect(view.superview == nil && window.subviews.isEmpty, "released after the hold")
        #expect(!writer.writeNow(0.5))
    }

    /// Stop and route changes drop the lease at once, even with a write still waiting.
    @Test func cancelReleasesTheVolumeViewAtOnce() async throws {
        let (writer, window, slider) = Self.writer()
        writer.write(0.5)
        writer.cancel()
        #expect(writer.view == nil && window.subviews.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(slider.writes.isEmpty, "a cancelled write never lands")
        #expect(writer.view == nil)
    }

    private final class RecordingSlider: UISlider {
        var writes: [Float] = []
        override func setValue(_ value: Float, animated: Bool) {
            writes.append(value)
            super.setValue(value, animated: animated)
        }
    }

    private static func writer() -> (MonitorRemoteShutterVolumeWriter, UIWindow, RecordingSlider) {
        let writer = MonitorRemoteShutterVolumeWriter(log: .init(subsystem: "SIMULATED", category: "test"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let slider = RecordingSlider()
        writer.hostWindow = { window }
        writer.makeView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.addSubview(slider)
            return view
        }
        return (writer, window, slider)
    }

    private static func waitUntil(seconds: Double = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(seconds) s")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
