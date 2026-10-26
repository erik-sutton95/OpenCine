#if os(iOS)
    import MonitorUI
    import OpenCineGyro
    import SwiftUI

    /// What the logs screens can ask of the host.
    public struct GyroLogsActions {
        public var share: ([UUID]) -> Void
        public var delete: (UUID) -> Void
        public var dismissTip: () -> Void
        public var turnOnGyro: () -> Void
        public var close: () -> Void

        public init(
            share: @escaping ([UUID]) -> Void = { _ in }, delete: @escaping (UUID) -> Void = { _ in },
            dismissTip: @escaping () -> Void = {}, turnOnGyro: @escaping () -> Void = {},
            close: @escaping () -> Void = {}
        ) {
            self.share = share
            self.delete = delete
            self.dismissTip = dismissTip
            self.turnOnGyro = turnOnGyro
            self.close = close
        }
    }

    /// The gyro logs: takes by day with one status badge each, a tip, select-and-share, and an
    /// empty state. Portrait pushes a take page; landscape shows the selected take beside the list.
    public struct GyroLogsView: View {
        private let entries: [GyroLogEntry]
        private let tipVisible: Bool
        private let gyroEnabled: Bool
        private let now: Date
        private let actions: GyroLogsActions

        @State private var selecting = false
        @State private var picked: Set<UUID> = []
        @State private var selectedID: UUID?
        @State private var pendingDelete: UUID?
        @State private var path: [UUID] = []

        public init(
            entries: [GyroLogEntry], tipVisible: Bool, gyroEnabled: Bool, now: Date,
            actions: GyroLogsActions
        ) {
            self.entries = entries
            self.tipVisible = tipVisible
            self.gyroEnabled = gyroEnabled
            self.now = now
            self.actions = actions
        }

        private var sections: [GyroLogSection] {
            GyroLogSections.group(entries, now: now, calendar: .current)
        }

        private var firstSelectable: UUID? {
            sections.flatMap(\.entries).first { !$0.active }?.id
        }

        private var effectiveSelection: GyroLogEntry? {
            let id = selectedID.flatMap { id in entries.first { $0.id == id }?.id }
                ?? firstSelectable
            return entries.first { $0.id == id }
        }

        public var body: some View {
            NavigationStack(path: $path) {
                GeometryReader { proxy in
                    let landscape = proxy.size.width >= proxy.size.height
                    ZStack {
                        MonitorTheme.background.ignoresSafeArea()
                        if entries.isEmpty {
                            emptyState
                        } else if landscape {
                            HStack(spacing: 0) {
                                list(split: true).frame(width: proxy.size.width * 0.4)
                                Rectangle().fill(GyroPalette.hairline).frame(width: 1)
                                detail.frame(maxWidth: .infinity)
                            }
                        } else {
                            list(split: false)
                        }
                    }
                }
                .navigationTitle(GyroCopy.logsTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .onChange(of: entries.filter(\.canShare).map(\.id)) { _, ids in
                    picked = picked.intersection(ids)
                }
                .navigationDestination(for: UUID.self) { id in
                    if let entry = entries.first(where: { $0.id == id }) {
                        GyroTakeView(entry: entry, now: now) { actions.share([entry.id]) }
                            .navigationTitle(entry.descriptor.startDate.formatted(
                                date: .omitted, time: .shortened))
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .confirmationDialog(
                    GyroCopy.deleteTitle, isPresented: deleteDialogBinding, titleVisibility: .visible
                ) {
                    Button(GyroCopy.delete, role: .destructive) {
                        if let id = pendingDelete { actions.delete(id) }
                        pendingDelete = nil
                    }
                    Button(GyroCopy.cancel, role: .cancel) { pendingDelete = nil }
                }
            }
            .preferredColorScheme(.dark)
        }

        private var deleteDialogBinding: Binding<Bool> {
            Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        }

        @ToolbarContentBuilder private var toolbar: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button(GyroCopy.cancel) {
                        selecting = false
                        picked = []
                    }
                    .tint(MonitorTheme.accent)
                    .accessibilityIdentifier("gyro.logs.cancelSelect")
                } else if !entries.isEmpty {
                    Button(GyroCopy.select) { selecting = true }
                        .tint(MonitorTheme.accent)
                        .accessibilityIdentifier("gyro.logs.select")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(GyroCopy.logsTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(GyroCopy.done, action: actions.close)
                    .fontWeight(.semibold)
                    .tint(MonitorTheme.accent)
                    .accessibilityIdentifier("gyro.logs.done")
            }
        }

        // MARK: List

        private func list(split: Bool) -> some View {
            let highlightedID = (!selecting && split) ? effectiveSelection?.id : nil
            return List {
                if tipVisible {
                    tip.listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(sections) { section in
                    Text(section.title.uppercased())
                        .font(.system(size: 12)).tracking(0.8)
                        .foregroundStyle(GyroPalette.overline)
                        .accessibilityAddTraits(.isHeader)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ForEach(section.entries) { entry in
                        row(entry, split: split, highlightedID: highlightedID)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !entry.active {
                                    Button(GyroCopy.delete, role: .destructive) {
                                        pendingDelete = entry.id
                                    }
                                }
                            }
                    }
                }
                Color.clear.frame(height: selecting ? 70 : 0)
                    .accessibilityHidden(true)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MonitorTheme.background)
            .overlay(alignment: .bottom) {
                if selecting { selectionBar }
            }
        }

        private var tip: some View {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(GyroPalette.body)
                    .accessibilityHidden(true)
                Text(GyroCopy.tip)
                    .font(.system(size: 14))
                    .foregroundStyle(GyroPalette.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.dismissTip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GyroPalette.overline)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(GyroCopy.dismissTip)
                .accessibilityIdentifier("gyro.logs.tipClose")
            }
            .padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 4)
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                    .stroke(GyroPalette.tipBorder, lineWidth: 1))
        }

        private func row(_ entry: GyroLogEntry, split: Bool, highlightedID: UUID?) -> some View {
            let status = entry.status
            let time = entry.descriptor.startDate.formatted(date: .omitted, time: .shortened)
            let subtitle = entry.rowSubtitle(now: now)
            let highlighted = entry.id == highlightedID
            return Button {
                tap(entry, split: split)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GyroPalette.tile)
                        if entry.active {
                            Circle().fill(GyroPalette.red).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(GyroPalette.body)
                        }
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(time).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(GyroPalette.overline)
                    }
                    Spacer(minLength: 8)
                    if selecting && entry.canShare {
                        Image(systemName: picked.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(
                                picked.contains(entry.id) ? MonitorTheme.accent : GyroPalette.overline)
                    }
                    GyroStatusBadge(status: status)
                }
                .padding(10)
                .background(
                    MonitorTheme.surface,
                    in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                        .stroke(MonitorTheme.accent, lineWidth: highlighted ? 1.5 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                [time, subtitle, GyroCopy.status(status)].joined(separator: ", "))
            .accessibilityAddTraits(
                (selecting && picked.contains(entry.id)) || highlighted
                    ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default) { tap(entry, split: split) }
            .accessibilityIdentifier("gyro.log.row")
            .accessibilityActions {
                if !entry.active {
                    Button(GyroCopy.delete) { pendingDelete = entry.id }
                }
            }
        }

        private func tap(_ entry: GyroLogEntry, split: Bool) {
            if selecting {
                guard !entry.active, entry.canShare else { return }
                if picked.contains(entry.id) { picked.remove(entry.id) } else { picked.insert(entry.id) }
            } else if split {
                selectedID = entry.id
            } else {
                path.append(entry.id)
            }
        }

        private var selectionBar: some View {
            GyroPrimaryButton(GyroCopy.shareCount(picked.count)) {
                let ids = sections.flatMap(\.entries).filter { $0.canShare && picked.contains($0.id) }
                    .map(\.id)
                actions.share(ids)
                selecting = false
                picked = []
            }
            .disabled(picked.isEmpty)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(MonitorTheme.background.opacity(0.95))
        }

        // MARK: Landscape detail and empty state

        @ViewBuilder private var detail: some View {
            if let entry = effectiveSelection {
                GyroTakeView(entry: entry, now: now, showsShare: !selecting) { actions.share([entry.id]) }
                    .id(entry.id)
            } else {
                MonitorTheme.background
            }
        }

        private var emptyState: some View {
            GyroAdaptiveStack(
                visual: { EmptyVisual() },
                header: {
                    VStack(spacing: 8) {
                        Text(GyroCopy.emptyTitle)
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Text(GyroCopy.emptyBody)
                            .font(.system(size: 15)).foregroundStyle(GyroPalette.body)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                },
                footer: {
                    if !gyroEnabled {
                        GyroPrimaryButton(GyroCopy.turnOnGyro, action: actions.turnOnGyro)
                    }
                })
        }
    }

    /// One trailing status badge: tinted capsule, solid red for a recording take.
    struct GyroStatusBadge: View {
        let status: GyroTakeStatus

        var body: some View {
            let tone = GyroStatusTone.badge(status)
            let live = status == .recording
            Text(GyroCopy.status(status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(live ? Color.white : tone)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(live ? tone : tone.opacity(0.15), in: Capsule())
                .fixedSize()
        }
    }

    /// A dotted ring with an accent wave line inside, the empty state's picture.
    private struct EmptyVisual: View {
        var body: some View {
            GeometryReader { proxy in
                let d = min(min(proxy.size.width, proxy.size.height) * 0.6, 200)
                ZStack {
                    Circle().stroke(
                        GyroPalette.track,
                        style: StrokeStyle(lineWidth: d * 0.1, dash: [d * 0.03, d * 0.06]))
                        .frame(width: d * 0.84, height: d * 0.84)
                    Wave().stroke(
                        MonitorTheme.accent,
                        style: StrokeStyle(lineWidth: d * 0.035, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: d * 0.45, height: d * 0.2)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GyroCopy.emptyTitle)
            .accessibilityIdentifier("gyro.visual")
        }
    }

    private struct Wave: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width / 4
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            for index in 0..<4 {
                let x0 = rect.minX + CGFloat(index) * w
                let up: CGFloat = index % 2 == 0 ? -1 : 1
                path.addQuadCurve(
                    to: CGPoint(x: x0 + w, y: rect.midY),
                    control: CGPoint(x: x0 + w / 2, y: rect.midY + up * rect.height * 0.9))
            }
            return path
        }
    }
#endif
