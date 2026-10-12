#if os(iOS)
import MonitorUI
import Observation
import OpenCineAppKit
import SwiftUI

/// The shared visual language projected into existing native control and assist views.
public enum MonitorDefaultLivePalette: LiveChromePalette {
    public static var background: Color { MonitorTheme.background }
    public static var glassBright: Color { MonitorTheme.raised }
    public static var hairline: Color { MonitorTheme.border }
    public static var hairlineStrong: Color { MonitorTheme.text.opacity(0.2) }
    public static var text: Color { MonitorTheme.text }
    public static var muted: Color { MonitorTheme.muted }
    public static var accent: Color { MonitorTheme.accent }
    public static var accentDim: Color { MonitorTheme.accent.opacity(0.14) }
    public static var onAccent: Color { MonitorTheme.onAccent }
    public static var rec: Color { MonitorTheme.recording }
    public static var destructive: Color { MonitorTheme.recording }
    public static var amber: Color { MonitorTheme.digitalCrop }
    public static var aeLock: Color { chromeColor(red: 1, green: 0.88, blue: 0.17) }
    public static var good: Color { MonitorTheme.linkHealthColor(.stable) }
    public static var cornerRadius: CGFloat { MonitorTheme.radius }
    public static func chromeColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        MonitorTheme.edrSRGB(red: red, green: green, blue: blue, gain: MonitorTheme.hdrGain)
    }
}

/// Existing measured editor chrome adapts the exercised AppKit owner, with no screen host.
@MainActor @Observable
final class MonitorOperatorEditorHost<Looks: MonitorLookProvider>: ChromeEditHost {
    typealias Palette = MonitorDefaultLivePalette
    typealias ChromeSection = MonitorDisplayChrome.Section
    typealias ChromeMode = MonitorDisplayMode
    let model: MonitorOperatorSessionModel<Looks>
    let preferences: MonitorOperatorPreferences
    init(model: MonitorOperatorSessionModel<Looks>, preferences: MonitorOperatorPreferences) {
        self.model = model; self.preferences = preferences
    }
    var hapticsEnabled: Bool { preferences.haptics }
    func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool {
        model.chrome(for: mode).isVisible(section)
    }
    func toggleChrome(_ section: ChromeSection, for mode: ChromeMode) { model.toggle(section, in: mode) }
    func endChromeEditing() { model.finishEditing() }
}
#endif
