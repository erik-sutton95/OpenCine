#if os(iOS)
import MonitorUI
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

    @Test func aNewOwnerIsIdleUntilTheHostArmsIt() {
        let owner = MonitorRemoteShutter(subsystem: "SIMULATED")
        #expect(!owner.isActive)
        owner.stop()
        #expect(!owner.isActive)
        #expect(!owner.update(enabled: false, monitorPresented: true, liveViewFront: true))
        #expect(!owner.isActive, "a disabled shutter never takes the audio session")
    }
}
#endif
