#if os(iOS)
import MonitorPresentation
import SwiftUI
import Testing

@testable import MonitorUI

@MainActor
struct MonitorAssistPaletteTrailingToolTests {
    @Test func trailingToolStaysOutOfFavoritesAndLastInTheExpandedMenu() {
        let palette = MonitorAssistPalette(
            tools: [
                .init(id: "lut", title: "LUT", enabled: false, hasOptions: true),
                .init(id: "falseColor", title: "FALSE", enabled: true, hasOptions: true),
            ],
            layout: .init(portrait: false, tablet: false, expanded: true, toolCount: 3,
                maximumWidth: 400, maximumHeight: 200),
            trailingTool: .init(id: "voiceControl", title: "VOICE", enabled: false, hasOptions: false),
            usageSeed: ["falseColor": 10, "voiceControl": 100],
            usage: .constant(MonitorToolUsage()), expanded: .constant(false),
            onToggle: { _ in }, onOptions: { _ in }, icon: { _ in EmptyView() })
        #expect(palette.orderedTools(frozen: false, pinned: []).map(\.id) == ["falseColor", "lut"])
        #expect(palette.orderedTools(frozen: true, pinned: ["lut", "falseColor"]).map(\.id) ==
            ["lut", "falseColor", "voiceControl"])
    }
}
#endif
