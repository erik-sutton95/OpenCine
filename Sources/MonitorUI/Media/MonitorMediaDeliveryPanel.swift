#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// The complete delivery card. Only a destination's small artwork slot is supplied
    /// by its host; headers, scrolling, options, service picker and footer are shared.
    public struct MonitorMediaDeliveryPanel<DestinationIcon: View>: View {
        private let value: MonitorMediaDeliveryValue
        private let maxCardHeight: CGFloat
        private let action: (MonitorMediaDeliveryValue.Action) -> Void
        private let destinationIcon: (String) -> DestinationIcon
        public init(
            value: MonitorMediaDeliveryValue, maxCardHeight: CGFloat = 520,
            action: @escaping (MonitorMediaDeliveryValue.Action) -> Void,
            @ViewBuilder destinationIcon: @escaping (String) -> DestinationIcon
        ) {
            self.value = value
            self.maxCardHeight = maxCardHeight
            self.action = action
            self.destinationIcon = destinationIcon
        }
        public var body: some View {
            ViewThatFits(in: .vertical) {
                card(scrolling: false)
                card(scrolling: true).frame(maxHeight: maxCardHeight)
            }
            .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 620 : 460)
            .frame(maxHeight: maxCardHeight, alignment: .bottom)
        }
        private func card(scrolling: Bool) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                if scrolling {
                    ScrollView { mainColumn }
                        .accessibilityIdentifier("monitor.share.optionsScroll").monitorScrollFade()
                } else {
                    mainColumn.fixedSize(horizontal: false, vertical: true)
                }
                if let footer = value.footer { footerView(footer).padding(.top, 12) }
            }
            .padding(16)
            .monitorGlass(in: RoundedRectangle(cornerRadius: 16), density: .delivery)
        }
        private var header: some View {
            HStack(spacing: 10) {
                if value.step == .destination {
                    Label {
                        Text("Share")
                    } icon: {
                        MonitorIcon.share.frame(width: 13, height: 13)
                    }
                    .font(MonitorTheme.font(14, weight: .bold)).kerning(1).textCase(.uppercase)
                    .foregroundStyle(MonitorTheme.text)
                } else {
                    Button {
                        action(.back)
                    } label: {
                        Label {
                            Text("Back")
                        } icon: {
                            MonitorIcon.chevronLeft.frame(width: 12, height: 12)
                        }
                        .font(MonitorTheme.font(13, weight: .semibold)).foregroundStyle(
                            MonitorTheme.accent)
                    }
                    .buttonStyle(MonitorSettingsButtonStyle()).accessibilityIdentifier(
                        "monitor.share.back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.title).font(MonitorTheme.font(9, weight: .bold)).tracking(1.8)
                            .textCase(.uppercase).foregroundStyle(MonitorTheme.text)
                        Text("Options").font(MonitorTheme.font(11, weight: .medium))
                            .foregroundStyle(MonitorTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    action(.close)
                } label: {
                    MonitorIcon.x.frame(width: 11.4, height: 11.4).foregroundStyle(
                        MonitorTheme.text
                    )
                    .frame(width: 30, height: 30).background(MonitorTheme.surface, in: Circle())
                    .overlay(Circle().stroke(MonitorTheme.border, lineWidth: 1))
                }
                .buttonStyle(MonitorSettingsButtonStyle()).accessibilityLabel("Close")
                .accessibilityIdentifier("monitor.share.close")
            }
        }
        private var mainColumn: some View {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.selectionLabel).font(MonitorTheme.font(15, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                    ForEach(Array(value.notices.enumerated()), id: \.offset) { _, notice in
                        Text(notice.text).font(MonitorTheme.font(12))
                            .foregroundStyle(
                                notice.accented ? MonitorTheme.accent : MonitorTheme.muted)
                    }
                }
                if value.step == .destination {
                    destinations
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if let service = value.service { serviceView(service) }
                        if let export = value.export { exportView(export) }
                    }
                }
                if let status = value.status {
                    Text(status).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }
        private var destinations: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DESTINATION")
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 7),
                        count: UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1), spacing: 7
                ) {
                    ForEach(value.destinations) { destination in
                        Button {
                            action(.destination(destination.id))
                        } label: {
                            HStack(spacing: 12) {
                                destinationIcon(destination.id).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.title).font(
                                        MonitorTheme.font(14, weight: .semibold)
                                    )
                                    .foregroundStyle(
                                        destination.enabled ? MonitorTheme.text : MonitorTheme.faint
                                    )
                                    Text(destination.subtitle).font(MonitorTheme.font(11))
                                        .foregroundStyle(MonitorTheme.muted)
                                }
                                Spacer()
                                MonitorIcon.chevronRight.frame(width: 12, height: 12)
                                    .foregroundStyle(MonitorTheme.faint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10).deliveryOptionPlate()
                        }
                        .buttonStyle(MonitorSettingsButtonStyle()).disabled(!destination.enabled)
                        .accessibilityIdentifier("monitor.share.destination.\(destination.id)")
                    }
                    ForEach(value.upcoming, id: \.self) { title in
                        HStack(spacing: 12) {
                            MonitorIcon.folder.frame(width: 24, height: 24)
                            Text(title).font(MonitorTheme.font(14, weight: .semibold))
                            Spacer(minLength: 8)
                            Text("Coming soon").font(MonitorTheme.font(11))
                        }
                        .foregroundStyle(MonitorTheme.muted).padding(.horizontal, 12).padding(
                            .vertical, 14
                        )
                        .background(
                            MonitorTheme.border.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
                        )
                        .accessibilityElement(children: .combine).accessibilityIdentifier(
                            "monitor.share.upcoming.\(title)")
                    }
                }
            }
        }
        @ViewBuilder private func serviceView(_ service: MonitorMediaDeliveryValue.Service)
            -> some View
        {
            VStack(alignment: .leading, spacing: 10) {
                switch service {
                case .internetGate(let heading, let message, let busy, let busyTitle):
                    sectionHeader(heading)
                    Text(message).font(MonitorTheme.font(13)).foregroundStyle(MonitorTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if busy {
                        busyLabel(busyTitle, size: 13)
                    } else {
                        Button {
                            action(.hopToInternet)
                        } label: {
                            Label {
                                Text("Hop to internet")
                            } icon: {
                                MonitorIcon.wifiOff.frame(width: 16, height: 16)
                            }
                            .deliveryActionLabel(enabled: true)
                        }.buttonStyle(MonitorSettingsButtonStyle())
                    }
                case .projects(
                    let heading, let help, let signInNotice, let loading, let error, let choices,
                    let selectedID, let allowsCreation, _):
                    sectionHeader(heading)
                    HStack(spacing: 4) {
                        Text("Project").font(MonitorTheme.font(14, weight: .semibold))
                            .foregroundStyle(MonitorTheme.text)
                        MonitorSettingsHelpBadge(text: help)
                    }
                    if let signInNotice {
                        Text(signInNotice).font(MonitorTheme.font(12)).foregroundStyle(
                            MonitorTheme.muted)
                    }
                    if loading {
                        busyLabel("Loading projects…", size: 12)
                    } else if let error {
                        Text(error).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.accent)
                        Button("Retry") { action(.retryProjects) }.font(
                            MonitorTheme.font(13, weight: .semibold)
                        )
                        .foregroundStyle(MonitorTheme.accent)
                    } else if let choices {
                        Menu {
                            if choices.isEmpty { Button("No projects") {}.disabled(true) }
                            ForEach(choices) { choice in
                                Button {
                                    action(.selection(.project, choice.id))
                                } label: {
                                    if choice.id == selectedID {
                                        Label {
                                            Text(choice.label)
                                        } icon: {
                                            MonitorIcon.check
                                        }
                                    } else {
                                        Text(choice.label)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                MonitorIcon.folder.frame(width: 14, height: 14).foregroundStyle(
                                    MonitorTheme.muted)
                                Text(
                                    service.selectedProjectLabel ?? "Select a project"
                                )
                                .font(MonitorTheme.font(13, weight: .semibold))
                                .foregroundStyle(
                                    service.selectedProjectLabel != nil
                                        ? MonitorTheme.text : MonitorTheme.muted
                                ).lineLimit(1)
                                Spacer()
                                MonitorIcon.chevronsUpDown.frame(width: 11, height: 11)
                                    .foregroundStyle(MonitorTheme.muted)
                            }.padding(.horizontal, 12).padding(.vertical, 10).deliveryOptionPlate()
                        }.buttonStyle(MonitorSettingsButtonStyle())
                        if allowsCreation {
                            Button {
                                action(.createProject)
                            } label: {
                                HStack(spacing: 10) {
                                    MonitorIcon.circlePlus.frame(width: 16, height: 16)
                                        .foregroundStyle(MonitorTheme.accent)
                                    Text("Create new project").font(
                                        MonitorTheme.font(13, weight: .semibold)
                                    ).foregroundStyle(MonitorTheme.text)
                                    Spacer()
                                }.padding(.horizontal, 12).padding(.vertical, 10)
                                    .deliveryOptionPlate()
                            }.buttonStyle(MonitorSettingsButtonStyle())
                        }
                    }
                }
            }
        }
        private func exportView(_ export: MonitorMediaDeliveryValue.Export) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("EXPORT")
                if let filename = export.filename {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Filename").font(MonitorTheme.font(12, weight: .semibold))
                            .foregroundStyle(MonitorTheme.muted)
                        Text(filename).font(MonitorTheme.font(13)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.text)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .deliveryOptionPlate()
                }
                if let toggle = export.convertLog { toggleRow(toggle, option: .convertLog) }
                if let choices = export.outputCurve {
                    selectionRow(choices, selection: .outputCurve)
                }
                if let toggle = export.bakeLUT { toggleRow(toggle, option: .bakeLUT) }
                if let toggle = export.bakeExposure { toggleRow(toggle, option: .bakeExposure) }
                if let choices = export.format {
                    selectionRow(choices, selection: .format).padding(12).deliveryOptionPlate()
                }
                if let toggle = export.includeMetadata {
                    toggleRow(toggle, option: .includeMetadata)
                }
                if let toggle = export.reupload { toggleRow(toggle, option: .reupload) }
            }
        }
        private func toggleRow(
            _ toggle: MonitorMediaDeliveryValue.Toggle, option: MonitorMediaDeliveryValue.Option
        ) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(toggle.title).font(MonitorTheme.font(12.5, weight: .semibold))
                        .foregroundStyle(toggle.enabled ? MonitorTheme.text : MonitorTheme.faint)
                    Text(toggle.help).font(MonitorTheme.font(10.5)).foregroundStyle(
                        MonitorTheme.muted
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(
                    "", isOn: Binding(get: { toggle.isOn }, set: { action(.option(option, $0)) })
                )
                .labelsHidden().accessibilityLabel(toggle.title).tint(MonitorTheme.accent)
                .scaleEffect(0.75).frame(width: 38, height: 44)
            }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
                .deliveryOptionPlate()
                .disabled(!toggle.enabled).opacity(toggle.enabled ? 1 : 0.55)
        }
        private func selectionRow(
            _ choices: MonitorMediaDeliveryValue.Choices,
            selection: MonitorMediaDeliveryValue.Selection
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                if !choices.title.isEmpty {
                    Text(choices.title).font(
                        MonitorTheme.font(selection == .outputCurve ? 14 : 12.5, weight: .semibold)
                    )
                    .foregroundStyle(MonitorTheme.text)
                }
                if let help = choices.help {
                    Text(help).font(MonitorTheme.font(10.5)).foregroundStyle(MonitorTheme.muted)
                }
                MonitorSegmentedControl(
                    options: choices.options.map { Optional($0.id) },
                    selection: Binding<String?>(
                        get: { choices.selectedID },
                        set: {
                            if let id = $0 { action(.selection(selection, id)) }
                        }), stacked: true,
                    title: { id in choices.options.first { $0.id == id }?.label ?? "" }
                )
                .buttonStyle(MonitorSettingsButtonStyle())
            }
        }
        private func footerView(_ footer: MonitorMediaDeliveryValue.Footer) -> some View {
            VStack(spacing: 10) {
                if let summary = footer.summary {
                    Text(summary).accessibilityIdentifier("monitor.share.summary").font(
                        MonitorTheme.font(9.5)
                    )
                    .monospacedDigit().foregroundStyle(MonitorTheme.muted).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
                if let choices = footer.postExport { selectionRow(choices, selection: .postExport) }
                Button {
                    action(.begin)
                } label: {
                    Text(footer.actionTitle).deliveryActionLabel(enabled: footer.enabled)
                }
                .buttonStyle(MonitorSettingsButtonStyle()).disabled(!footer.enabled)
                .accessibilityIdentifier("monitor.share.begin")
            }
        }
        private func sectionHeader(_ title: String) -> some View {
            Text(title).font(MonitorTheme.font(11, weight: .bold)).monospacedDigit().kerning(0.6)
                .foregroundStyle(MonitorTheme.faint)
        }
        private func busyLabel(_ title: String, size: CGFloat) -> some View {
            HStack(spacing: 8) {
                ProgressView().tint(MonitorTheme.accent)
                Text(title).font(MonitorTheme.font(size)).foregroundStyle(MonitorTheme.muted)
            }
        }
    }

    extension View {
        fileprivate func deliveryOptionPlate() -> some View {
            background(
                MonitorTheme.border.opacity(0.35),
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous))
        }
        fileprivate func deliveryActionLabel(enabled: Bool) -> some View {
            font(MonitorTheme.font(15, weight: .semibold)).foregroundStyle(
                enabled ? MonitorTheme.text : MonitorTheme.faint
            )
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(
                enabled ? MonitorTheme.accent.opacity(0.22) : MonitorTheme.border.opacity(0.25),
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                    .strokeBorder(
                        enabled
                            ? MonitorTheme.accent.opacity(0.55) : MonitorTheme.border.opacity(0.35),
                        lineWidth: 1))
        }
    }

    public struct MonitorMediaDeliveryProgress<DestinationIcon: View>: View {
        private let value: MonitorMediaDeliveryProgressValue
        private let onCancel: (() -> Void)?
        private let onExpand: (() -> Void)?
        private let destinationIcon: DestinationIcon

        public init(
            value: MonitorMediaDeliveryProgressValue,
            onCancel: (() -> Void)? = nil,
            onExpand: (() -> Void)? = nil,
            @ViewBuilder destinationIcon: () -> DestinationIcon
        ) {
            self.value = value
            self.onCancel = onCancel
            self.onExpand = onExpand
            self.destinationIcon = destinationIcon()
        }

        public var body: some View {
            MonitorMediaDeliveryProgressContent(
                value: value,
                onCancel: onCancel,
                onExpand: onExpand,
                destinationIcon: destinationIcon
            )
            .padding(.horizontal, 14).padding(.vertical, 10)
            .monitorGlass(in: RoundedRectangle(cornerRadius: 12), density: .delivery)
        }
    }
#endif
