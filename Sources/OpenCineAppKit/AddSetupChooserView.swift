#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// Shared chooser rendering, usable inside a setup flow or a host's network wizard.
    public struct AddSetupChooserView: View {
        public var chooser: AddSetupChooser
        public var onSelect: (AddSetupOption) -> Void
        public var horizontal: Bool
        public var onNoticeAction: (String) -> Void

        public init(
            chooser: AddSetupChooser, onSelect: @escaping (AddSetupOption) -> Void,
            horizontal: Bool = false, onNoticeAction: @escaping (String) -> Void = { _ in }
        ) {
            self.chooser = chooser
            self.onSelect = onSelect
            self.horizontal = horizontal
            self.onNoticeAction = onNoticeAction
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(chooser.title).font(MonitorTheme.font(18, weight: .semibold))
                if !chooser.detail.isEmpty {
                    Text(chooser.detail).font(MonitorTheme.font(13)).foregroundStyle(
                        MonitorTheme.muted)
                }
                if let notice = chooser.notice {
                    Text(notice.message).font(MonitorTheme.font(12.5)).foregroundStyle(
                        MonitorTheme.muted)
                    Button(notice.actionTitle) { onNoticeAction(notice.id) }
                }
                let layout =
                    horizontal && chooser.options.count == 2
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    ForEach(chooser.options) { option in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(option.title).font(MonitorTheme.font(15, weight: .semibold))
                            Text(option.detail).font(MonitorTheme.font(12.5)).foregroundStyle(
                                MonitorTheme.muted
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            Button(option.actionTitle) {
                                chooser.select(option.id, onSelect: onSelect)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!option.enabled)
                            .accessibilityIdentifier("\(chooser.identifierPrefix).\(option.id)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let footer = chooser.footer {
                    Text(footer).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
                }
            }
            .foregroundStyle(MonitorTheme.text)
            // Chooser actions read the same in every app, never the host's accent.
            .tint(MonitorTheme.text)
        }
    }

    /// Renders the shared choice before an optional integration destination; dismissal sends no command itself.
    public struct AddSetupFlowView: View {
        public var flow: AddSetupFlow
        @State private var selected: String?
        @Environment(\.monitorWindowGeometry) private var windowGeometry

        public nonisolated init(flow: AddSetupFlow) {
            self.flow = flow
            _selected = State(initialValue: flow.initialSelection)
        }

        public var body: some View {
            VStack(spacing: 0) {
                if let option = flow.chooser.options.first(where: {
                    $0.id == selected && $0.enabled
                }),
                    let destination = flow.destination
                {
                    destination(option)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            AddSetupChooserView(
                                chooser: flow.chooser,
                                onSelect: {
                                    if flow.destination != nil {
                                        selected = $0.id
                                    } else {
                                        flow.onSelect($0)
                                    }
                                },
                                horizontal: windowGeometry.size.width > windowGeometry.size.height,
                                onNoticeAction: flow.onNoticeAction)
                            if let title = flow.cancelTitle {
                                Button(title, action: flow.onCancel).tint(MonitorTheme.text)
                            }
                        }
                        .padding(20)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .background(MonitorTheme.background)
                }
            }
            .onDisappear(perform: flow.onDismiss)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
#endif
