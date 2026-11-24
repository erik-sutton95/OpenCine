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

    /// The camera tabs in the module window's title bar. Names come from the modules' manifests.
    @available(macCatalyst 17.0, *)
    struct DesktopTabBar: View {
        let model: DesktopTabBarModel

        var body: some View {
            HStack(spacing: 4) {
                ForEach(model.tabs, id: \.id) { tab in
                    let selected = model.selectedID == tab.id
                    Button {
                        model.onSelect(tab.id)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Self.color(for: tab.state)).frame(width: 8, height: 8)
                            Text(tab.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if tab.state == .stopped {
                                Text("Restart").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            selected ? Color.primary.opacity(0.14) : .clear, in: .rect(cornerRadius: 7)
                        )
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
            case .live: .green
            case .connecting: .yellow
            case .failed, .stopped: .red
            case .idle: .gray
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

    /// The dock's notice at the trailing end of the title bar, such as the driver awaiting approval.
    @available(macCatalyst 17.0, *)
    struct DesktopTabNotice: View {
        static let driverSettingsURL = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        let model: DesktopTabBarModel

        var body: some View {
            Group {
                if let notice = model.notice, !notice.text.isEmpty {
                    if notice.opensDriverSettings {
                        Button(notice.text) { UIApplication.shared.open(Self.driverSettingsURL) }
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

    /// Puts the tab bar in each window scene's title bar as a unified toolbar: the tabs lead, a
    /// flexible space follows (empty toolbar space drags the window, as in any Mac window), and the
    /// notice trails. The system lays the items out after the window buttons.
    @available(macCatalyst 17.0, *)
    @MainActor
    final class DesktopTabToolbar: NSObject, NSToolbarDelegate {
        static let barHeight: CGFloat = 44
        private static let identifier = "com.opencapture.opencine.tabs"
        private static let tabsItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.bar")
        private static let noticeItem = NSToolbarItem.Identifier("com.opencapture.opencine.tabs.notice")

        private let model: DesktopTabBarModel
        /// Hosting controllers stay alive as long as their views sit in a toolbar.
        private var hosts: [UIViewController] = []
        private var toolbars: [ObjectIdentifier: NSToolbar] = [:]

        init(model: DesktopTabBarModel) {
            self.model = model
        }

        /// Installs the bar on every connected window scene that does not have it yet. Cheap enough
        /// to call on a timer, which also puts it back if a scene update replaced the toolbar.
        func installOnConnectedScenes() {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                install(on: scene)
            }
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

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.tabsItem, .flexibleSpace, Self.noticeItem]
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
            case Self.tabsItem: view = AnyView(DesktopTabBar(model: model))
            case Self.noticeItem: view = AnyView(DesktopTabNotice(model: model))
            default: return nil
            }
            let host = UIHostingController(rootView: view)
            // The item takes the view's own size, so the space after the tabs stays empty title bar.
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            hosts.append(host)
            return NSUIViewToolbarItem(itemIdentifier: itemIdentifier, uiView: host.view)
        }
    }
#endif
