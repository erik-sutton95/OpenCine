import MonitorPresentation
import Testing

/// The desktop status row: what the phone shows on top of the picture, in one row under the
/// title bar (spec 2026-11-25-desktop-camera-window-toolbar-design.md).
struct MonitorDesktopStatusTests {
    @Test func statusMapsFromThePresentation() {
        let status = MonitorDesktopStatus.from(
            fps: "25", signalBars: 3,
            battery: .init(percent: 80), storage: "124 GB", format: ["4K", "25p"],
            logProfile: "I-Log", mode: "Video")
        #expect(status.chips.map(\.kind) == [.link, .battery, .card, .format, .logProfile, .mode])
        #expect(status.link == .init(kind: .link, text: nil, bars: 3, tint: .good))
        #expect(status.battery == .init(kind: .battery, text: "80%", tint: .plain))
        #expect(status.card?.text == "124 GB")
        #expect(status.format?.text == "4K 25p")
        #expect(status.logProfile?.text == "I-Log")
        #expect(status.mode?.text == "Video")

        // A coarse gauge prints its steps and keeps its urgency; a held feed names its state.
        let held = MonitorDesktopStatus.from(
            fps: "NO LINK", signalBars: nil, battery: .init(bars: 1, barCount: 5),
            storage: nil, format: [], logProfile: nil, mode: nil)
        #expect(held.link == .init(kind: .link, text: "NO LINK", bars: nil, tint: .depleted))
        #expect(held.battery == .init(kind: .battery, text: "1/5", tint: .depleted))
        // Without bars the link shows the feed's rate.
        let rate = MonitorDesktopStatus.from(
            fps: "24.98", signalBars: nil, battery: nil, storage: nil, format: [], logProfile: nil, mode: nil)
        #expect(rate.link?.text == "25 fps")
        // A body on external power that reports no level reads EXT.
        let external = MonitorDesktopStatus.from(
            fps: nil, signalBars: nil, battery: .init(externalPower: true), storage: nil, format: [],
            logProfile: nil, mode: nil)
        #expect(external.battery?.text == "EXT")
    }

    @Test func missingValuesAreOmitted() {
        // A camera on an HDMI capture reports no link, battery or card: no empty chip, no dash.
        let status = MonitorDesktopStatus.from(
            fps: nil, signalBars: nil, battery: nil, storage: "--", format: ["--", " "],
            logProfile: "", mode: "\u{2014}")
        #expect(status.chips.isEmpty)
        // A battery with no level and no power source is unknown, not 0%.
        let unknown = MonitorDesktopStatus.from(
            fps: nil, signalBars: nil, battery: .init(), storage: nil, format: ["4K", "--"],
            logProfile: nil, mode: nil)
        #expect(unknown.battery == nil)
        #expect(unknown.chips.map(\.kind) == [.format])
        #expect(unknown.format?.text == "4K")
    }

    @Test func logProfileUsesTheAccent() {
        let status = MonitorDesktopStatus.from(
            fps: "25", signalBars: 4, battery: .init(percent: 50), storage: "64 GB", format: ["4K"],
            logProfile: "D-Log M", mode: "Video")
        #expect(status.logProfile?.tint == .accent)
        #expect(status.chips.filter { $0.tint == .accent }.map(\.kind) == [.logProfile])
    }
}
