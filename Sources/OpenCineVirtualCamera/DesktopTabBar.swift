#if targetEnvironment(macCatalyst)
    import Foundation
    import OpenCineDesktopKit
    import SwiftUI
    import UIKit

    /// What the dock last said the tab bar shows. Every module draws the same tabs; the dock owns them.
    @available(macCatalyst 17.0, *)
    @MainActor @Observable
    final class DesktopTabBarModel {
        var tabs: [DockTab] = []
        var selectedID: String?
        var notice: DockNotice?
        @ObservationIgnored var onSelect: (String) -> Void = { _ in }
    }

    /// The monitor's look in the toolbar. Neutral surfaces mirror the monitor theme (MonitorUI
    /// `MonitorTheme`), which this module cannot import; the accent and font arrive from the monitor
    /// through `DesktopCommands`.
    @available(macCatalyst 17.0, *)
    enum DesktopToolbarLook {
        static let text = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF0 / 255)
        static let secondary = text.opacity(0.72)
        static let muted = text.opacity(0.5)
        static let faint = text.opacity(0.28)
        static let raised = Color(red: 0x22 / 255, green: 0x24 / 255, blue: 0x25 / 255)
        static let border = Color.white.opacity(0.08)
        static let live = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
        static let warning = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
        /// The monitor's recording colour.
        static let recording = Color(red: 209 / 255, green: 48 / 255, blue: 52 / 255)

        static func font(_ family: String?, _ size: CGFloat, face: String) -> Font {
            guard let family else { return .system(size: size, weight: face == "Bold" ? .bold : .semibold) }
            return .custom("\(family)-\(face)", size: size)
        }
    }

    /// The camera tabs in the module window's title bar, flat: the selected tab on a raised surface.
    /// Names come from the modules' manifests.
    @available(macCatalyst 17.0, *)
    struct DesktopTabBar: View {
        let model: DesktopTabBarModel
        let commands: DesktopCommands

        var body: some View {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.id) { tab in
                    let selected = model.selectedID == tab.id
                    Button {
                        model.onSelect(tab.id)
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Self.color(for: tab.state)).frame(width: 7, height: 7)
                            Text(tab.displayName)
                                .font(DesktopToolbarLook.font(commands.fontFamily, 12.5, face: "Medium"))
                                .lineLimit(1)
                            if tab.state == .stopped {
                                Text("Restart")
                                    .font(DesktopToolbarLook.font(commands.fontFamily, 11.5, face: "Regular"))
                                    .foregroundStyle(DesktopToolbarLook.faint)
                            }
                        }
                        .foregroundStyle(selected ? DesktopToolbarLook.text : DesktopToolbarLook.muted)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(DesktopToolbarLook.raised)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(DesktopToolbarLook.border)
                                    }
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.accessibilityLabel(for: tab))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(height: DesktopTabToolbar.barHeight)
            .fixedSize()
        }

        static func color(for state: DockTab.State) -> Color {
            switch state {
            case .live: DesktopToolbarLook.live
            case .connecting: DesktopToolbarLook.warning
            case .failed, .stopped: DesktopToolbarLook.recording
            case .idle: DesktopToolbarLook.faint
            }
        }

        static func accessibilityLabel(for tab: DockTab) -> String {
            switch tab.state {
            case .live: "\(tab.displayName), live"
            case .connecting: "\(tab.displayName), connecting"
            case .failed: "\(tab.displayName), failed"
            case .stopped: "\(tab.displayName), stopped. Restart."
            case .idle: "\(tab.displayName), no camera connected"
            }
        }
    }

    /// The take in the toolbar: STBY (muted) or REC (the recording colour), then the timecode, then
    /// a separator before the buttons. It reads the take as the timecode advances.
    @available(macCatalyst 17.0, *)
    struct DesktopTakeItem: View {
        let commands: DesktopCommands

        var body: some View {
            Group {
                if commands.readTake != nil {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                        let title = commands.take.title
                        HStack(spacing: 8) {
                            Text(title.state)
                                .font(DesktopToolbarLook.font(commands.fontFamily, 9.5, face: "Bold"))
                                .tracking(1.1)
                                .foregroundStyle(
                                    title.role == .recording ? DesktopToolbarLook.recording : DesktopToolbarLook.muted)
                            if let timecode = title.timecode {
                                Text(timecode)
                                    .font(DesktopToolbarLook.font(commands.fontFamily, 11.5, face: "SemiBold"))
                                    .monospacedDigit()
                                    .foregroundStyle(DesktopToolbarLook.secondary)
                            }
                            Rectangle().fill(DesktopToolbarLook.border).frame(width: 1, height: 18)
                                .padding(.leading, 6)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title.role == .recording ? "Recording" : "Standing by")
                        .accessibilityValue(title.timecode ?? "")
                    }
                }
            }
            .frame(height: DesktopTabToolbar.barHeight)
            .fixedSize()
        }
    }

    /// The dock's notice at the trailing end of the title bar, such as the driver awaiting approval.
    @available(macCatalyst 17.0, *)
    struct DesktopTabNotice: View {
        let model: DesktopTabBarModel

        var body: some View {
            Group {
                if let notice = model.notice, !notice.text.isEmpty {
                    if notice.opensDriverSettings {
                        Button(notice.text) { UIApplication.shared.open(DockNotice.driverSettingsURL) }
                            .font(.system(size: 12, weight: .medium))
                            .accessibilityHint(
                                "Opens System Settings. Turn on OpenCine Camera under Camera Extensions.")
                    } else {
                        Text(notice.text).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .frame(height: DesktopTabToolbar.barHeight)
            .fixedSize()
        }
    }

    /// Puts the toolbar in each window scene's title bar as a unified toolbar: the tabs lead, a
    /// flexible space follows (empty toolbar space drags the window, as in any Mac window), then the
    /// take, Media and Settings, and the notice trails. The system lays the items out after the
    /// window buttons.
    @available(macCatalyst 17.0, *)
    @MainActor
    final class DesktopTabToolbar: NSObject, NSToolbarDelegate {
        static let barHeight: CGFloat = 44
        private static let identifier = "com.opencapture.opencine.tabs"
        private static let tabsItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.bar")
        private static let takeItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.take")
        private static let mediaItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.media")
        private static let settingsItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.settings")
        private static let noticeItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.notice")

        private let model: DesktopTabBarModel
        private let commands: DesktopCommands
        /// Hosting controllers stay alive as long as their views sit in a toolbar.
        private var hosts: [ObjectIdentifier: [UIViewController]] = [:]
        private var toolbars: [ObjectIdentifier: NSToolbar] = [:]
        /// The Media and Settings buttons, to keep their state with the registered actions.
        private var buttons: [NSToolbarItem] = []

        init(model: DesktopTabBarModel, commands: DesktopCommands) {
            self.model = model
            self.commands = commands
        }

        /// Installs the bar on every connected window scene that does not have it yet. Cheap enough
        /// to call on a timer, which also puts it back if a scene update replaced the toolbar.
        func installOnConnectedScenes() {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            // Forget scenes that are gone, with their toolbars.
            let connected = Set(scenes.map(ObjectIdentifier.init))
            toolbars = toolbars.filter { connected.contains($0.key) }
            let live = Set(toolbars.values.map(ObjectIdentifier.init))
            hosts = hosts.filter { live.contains($0.key) }
            for scene in scenes { install(on: scene) }
            refreshButtons()
        }

        private func install(on scene: UIWindowScene) {
            guard let titlebar = scene.titlebar else { return }
            let key = ObjectIdentifier(scene)
            if let toolbar = toolbars[key], titlebar.toolbar === toolbar { return }
            let toolbar = toolbars[key] ?? NSToolbar(identifier: Self.identifier)
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            toolbars[key] = toolbar
            titlebar.titleVisibility = .hidden
            titlebar.toolbarStyle = .unified
            titlebar.toolbar = toolbar
        }

        /// An item whose action the monitor has not registered is disabled; the icons follow the
        /// monitor's.
        private func refreshButtons() {
            buttons.removeAll { $0.toolbar == nil }
            for item in buttons {
                let settings = item.itemIdentifier == Self.settingsItem
                let enabled = settings ? commands.openSettings != nil : commands.openMedia != nil
                if item.isEnabled != enabled { item.isEnabled = enabled }
                let image = Self.image(settings: settings, commands: commands)
                if item.image !== image { item.image = image }
            }
        }

        private static func image(settings: Bool, commands: DesktopCommands) -> UIImage? {
            (settings ? commands.settingsIcon : commands.mediaIcon)
                ?? UIImage(systemName: settings ? "gearshape" : "film")
        }

        @objc private func openMedia(_ sender: Any?) { commands.openMedia?() }
        @objc private func openSettings(_ sender: Any?) { commands.openSettings?() }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.tabsItem, .flexibleSpace, Self.takeItem, Self.mediaItem, Self.settingsItem, Self.noticeItem]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            let view: AnyView
            switch itemIdentifier {
            case Self.tabsItem: view = AnyView(DesktopTabBar(model: model, commands: commands))
            case Self.takeItem: view = AnyView(DesktopTakeItem(commands: commands))
            case Self.noticeItem: view = AnyView(DesktopTabNotice(model: model))
            case Self.mediaItem, Self.settingsItem:
                // Real toolbar buttons: the whole item is the click target.
                let settings = itemIdentifier == Self.settingsItem
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = settings ? "Settings" : "Media"
                item.toolTip = settings ? "Camera settings (\u{2318},)" : "Media (\u{21E7}\u{2318}M)"
                item.image = Self.image(settings: settings, commands: commands)
                item.isBordered = true
                // Enabled follows the registered actions, not the responder chain.
                item.autovalidates = false
                item.target = self
                item.action = settings ? #selector(openSettings(_:)) : #selector(openMedia(_:))
                item.isEnabled = settings ? commands.openSettings != nil : commands.openMedia != nil
                buttons.append(item)
                return item
            default: return nil
            }
            let host = UIHostingController(rootView: view)
            // The item takes the view's own size, so the space after the tabs stays empty title bar.
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            hosts[ObjectIdentifier(toolbar), default: []].append(host)
            return NSUIViewToolbarItem(itemIdentifier: itemIdentifier, uiView: host.view)
        }
    }
#endif
