#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UniformTypeIdentifiers

    /// The app's words for its official looks in the LUT picker.
    public struct LUTPickerCopy: Sendable {
        /// The first tab's title, the maker of the official cubes.
        public let officialTab: String
        /// Caption under a locked official row.
        public let officialLockedCaption: String
        /// Caption on the official tab while another tab's look is selected.
        public let officialCaption: String
        /// The custom tab's hint before any import.
        public let customEmptyHint: String

        public init(
            officialTab: String, officialLockedCaption: String, officialCaption: String,
            customEmptyHint: String
        ) {
            self.officialTab = officialTab
            self.officialLockedCaption = officialLockedCaption
            self.officialCaption = officialCaption
            self.customEmptyHint = customEmptyHint
        }

        /// Live Photo / Photo is Rec.709; do not label a stale D-Log conversion.
        public static let photoRec709Caption =
            "Photo live view is Rec.709 \u{2014} log conversions are off"
    }

    /// The camera session the LUT picker binds Auto to, read by the app from its model.
    public struct LUTPickerContext: Equatable {
        public var colorMode: ColorMode?
        public var isPhoto: Bool
        public var inPlayback: Bool
        public var family: CameraBodyFamily
        public var cameraName: String?
        public var isWatching: Bool
        public var lookProfile: CameraLUTProfile?

        public init(
            colorMode: ColorMode?, isPhoto: Bool, inPlayback: Bool, family: CameraBodyFamily,
            cameraName: String?, isWatching: Bool, lookProfile: CameraLUTProfile? = nil
        ) {
            self.colorMode = colorMode
            self.isPhoto = isPhoto
            self.inPlayback = inPlayback
            self.family = family
            self.cameraName = cameraName
            self.isWatching = isWatching
            self.lookProfile = lookProfile
        }
    }

    /// Official / Creative / Custom. 50/50 is pinned on the long-press footer so
    /// landscape never hides it under the catalog; the sheet keeps it inline (`footer`).
    /// `embedded` is the assist-tray form; the sheet wraps the same body.
    public struct LUTPickerView<Palette: LiveChromePalette, Footer: View>: View {
        private enum Category: CaseIterable {
            case official
            case creative
            case custom
        }

        @Bindable var assist: MonitorAssistState<MonitorLUTLooks>
        let embedded: Bool
        let context: LUTPickerContext
        let copy: LUTPickerCopy
        let footer: Footer
        @Environment(\.dismiss) private var dismiss
        @State private var category: Category = .official
        @State private var importing = false
        @State private var pendingDeletion: String?
        @State private var deletionErrorMessage: String?
        @State private var importError: String?

        /// Reference monitor `LUTPickerContent.contentHeight`: landscape has no headroom for a
        /// taller drum.
        private let contentHeight: CGFloat = 146
        private let captionHeight: CGFloat = 28

        public init(
            assist: MonitorAssistState<MonitorLUTLooks>, embedded: Bool = false,
            context: LUTPickerContext, copy: LUTPickerCopy, palette _: Palette.Type,
            @ViewBuilder footer: () -> Footer
        ) {
            self.assist = assist
            self.embedded = embedded
            self.context = context
            self.copy = copy
            self.footer = footer()
        }

        public var body: some View {
            if embedded {
                picker
            } else {
                NavigationStack {
                    picker
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Palette.background.ignoresSafeArea())
                        .navigationTitle("LUT")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }

        private func title(_ category: Category) -> String {
            switch category {
            case .official: copy.officialTab
            case .creative: "Creative"
            case .custom: "Custom"
            }
        }

        private var picker: some View {
            VStack(spacing: 8) {
                MonitorCaptureTabs(
                    options: Category.allCases.map(title),
                    selection: title(category), title: { $0 }
                ) { raw in
                    guard let next = Category.allCases.first(where: { title($0) == raw }),
                        next != category
                    else { return }
                    category = next
                    switch next {
                    case .official:
                        if !assist.lutSelection.isOfficial { assist.selectLUT(.officialAuto) }
                    case .creative:
                        if !assist.lutSelection.isCreative { assist.selectLUT(.creativeMono) }
                    case .custom:
                        break
                    }
                }
                tabContent
                    .frame(maxWidth: .infinity)
                    .frame(height: contentHeight)
                // Embedded long-press parks exposure + 50/50 on the panel footer
                // so landscape never hides them under the catalog.
                if !embedded {
                    footer
                }
                if let importError {
                    Text(importError)
                        .font(MonitorTheme.font(12, weight: .regular))
                        .foregroundStyle(Palette.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if assist.lutSelection.isCustom {
                    category = .custom
                } else if assist.lutSelection.isCreative {
                    category = .creative
                } else {
                    category = .official
                }
                bindLiveLUT()
            }
            .onChange(of: context.isPhoto) { _, _ in
                bindLiveLUT()
            }
            .onChange(of: context.colorMode) { _, _ in
                bindLiveLUT()
            }
            .confirmationDialog(
                pendingDeletion.map { "Clear \(CustomLUTIndex.displayName(fileName: $0))?" }
                    ?? "Clear LUT?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                if let pendingDeletion {
                    Button("Clear LUT", role: .destructive) {
                        clear(pendingDeletion)
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This removes the stored LUT from this device. This action cannot be undone.")
            }
            .alert(
                "Couldn’t Delete LUT",
                isPresented: Binding(
                    get: { deletionErrorMessage != nil },
                    set: { if !$0 { deletionErrorMessage = nil } })
            ) {
                Button("OK") { deletionErrorMessage = nil }
            } message: {
                Text(deletionErrorMessage ?? "The LUT could not be deleted.")
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]
            ) { result in
                handleImport(result)
            }
        }

        @ViewBuilder private var tabContent: some View {
            switch category {
            case .official:
                let catalog = assist.looks.official.catalog(livePhotoCatalog)
                catalogTab(
                    cases: catalog,
                    inCatalog: assist.lutSelection.isOfficial
                        && catalog.contains(assist.lutSelection),
                    fallback: .officialAuto,
                    caption: officialCaption,
                    allowsSelection: !livePhotoCatalog
                )
            case .creative:
                catalogTab(
                    cases: LUTSelection.creativeCases,
                    inCatalog: assist.lutSelection.isCreative,
                    fallback: .creativeMono,
                    caption: creativeCaption
                )
            case .custom:
                customTab
            }
        }

        private func catalogTab(
            cases: [LUTSelection],
            inCatalog: Bool,
            fallback: LUTSelection,
            caption: String,
            allowsSelection: Bool = true
        ) -> some View {
            VStack(spacing: 4) {
                Text(caption)
                    .font(MonitorTheme.font(11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(height: captionHeight)
                LUTDrumWheel<Palette>(
                    options: cases.map(\.title),
                    selection: Binding(
                        get: {
                            inCatalog ? assist.lutSelection.title : fallback.title
                        },
                        set: { name in
                            // A singleton Photo catalog must not overwrite the saved Video look
                            // when scrollPosition reports its displayed fallback on mount.
                            guard allowsSelection else { return }
                            guard let selection = cases.first(where: { $0.title == name }) else {
                                return
                            }
                            assist.selectLUT(selection)
                        }
                    ),
                    wheelHeight: contentHeight - captionHeight - 4
                )
            }
        }

        private var livePhotoCatalog: Bool {
            context.isPhoto && !context.inPlayback && !assist.gradesClip && !context.isWatching
        }

        private func bindLiveLUT() {
            assist.bindLUTPicker(
                live: context.colorMode,
                inPlayback: context.inPlayback,
                family: context.family,
                cameraName: context.cameraName,
                lookProfile: context.lookProfile,
                isPhoto: context.isPhoto,
                isWatching: context.isWatching)
        }

        private var officialCaption: String {
            if livePhotoCatalog { return LUTPickerCopy.photoRec709Caption }
            if assist.lutSelection == .officialAuto || assist.lutSelection == .auto {
                return LUTResolver.autoCaption(source: assist.resolvedSource())
            }
            if assist.lutSelection.isOfficial {
                return copy.officialLockedCaption
            }
            return copy.officialCaption
        }

        private var creativeCaption: String {
            if assist.lutSelection.isCreative {
                return LUTResolver.autoCaption(source: assist.resolvedSource())
            }
            return "Looks for the displayed picture"
        }

        @ViewBuilder private var customTab: some View {
            let imported = assist.looks.customLUTs.list()
            VStack(spacing: 6) {
                Button {
                    importing = true
                } label: {
                    Text("Import .cube")
                        .font(MonitorTheme.font(13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Palette.glassBright, in: Capsule())
                }
                .buttonStyle(.monitorTapTarget)
                if imported.isEmpty {
                    Text(copy.customEmptyHint)
                        .font(MonitorTheme.font(11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(imported, id: \.fileName) { lut in
                                customFileRow(lut)
                            }
                        }
                    }
                    .monitorScrollFade()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        private func customFileRow(_ lut: StoredCustomLUT) -> some View {
            let selected =
                assist.lutSelection == .customFile
                && assist.looks.preferences.selectedCustomFileName == lut.fileName
            return HStack(spacing: 6) {
                Button {
                    assist.selectCustomFile(lut.fileName)
                } label: {
                    Text(lut.displayName)
                        .font(MonitorTheme.font(13, weight: .semibold))
                        .foregroundStyle(selected ? Palette.accent : Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.monitorTapTarget)
                Button {
                    pendingDeletion = lut.fileName
                } label: {
                    Text("Clear")
                        .font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(Palette.destructive)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Palette.glassBright, in: Capsule())
                }
                .buttonStyle(.monitorTapTarget)
                .fixedSize()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Palette.accentDim : Palette.glassBright,
                in: RoundedRectangle(cornerRadius: Palette.cornerRadius, style: .continuous)
            )
        }

        private func handleImport(_ result: Result<URL, Error>) {
            switch result {
            case .success(let url):
                importCube(url)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }

        private func importCube(_ url: URL) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let store = assist.looks.customLUTs
            do {
                let stored = try store.importFile(from: url)
                guard store.cube(stored) != nil else {
                    try? store.remove(stored)
                    throw CustomLUTStoreError.unreadable
                }
                assist.importCustom(fileName: stored.fileName)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }

        private func clear(_ fileName: String) {
            pendingDeletion = nil
            assist.clearCustomFile(fileName)
        }
    }

    /// The vertical LUT wheel: the snapped row is the selection.
    public struct LUTDrumWheel<Palette: LiveChromePalette>: View {
        let options: [String]
        @Binding var selection: String
        /// Options flagged with a small star (a recommended look); empty draws none.
        var markedValues: Set<String> = []
        var wheelHeight: CGFloat = 146
        /// A long-press delete for removable options; nil keeps the wheel read-only.
        var onDeleteOption: ((String) -> Void)? = nil

        private let rowHeight: CGFloat = 52

        public init(
            options: [String], selection: Binding<String>, markedValues: Set<String> = [],
            wheelHeight: CGFloat = 146, onDeleteOption: ((String) -> Void)? = nil
        ) {
            self.options = options
            _selection = selection
            self.markedValues = markedValues
            self.wheelHeight = wheelHeight
            self.onDeleteOption = onDeleteOption
        }

        public var body: some View {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in
                            optionRow(option, isCentered: option == selection)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(
                    id: Binding(
                        get: { selection }, set: { if let value = $0 { selection = value } })
                )
                .contentMargins(
                    .vertical, max(0, (wheelHeight - rowHeight) / 2), for: .scrollContent
                )
                .frame(height: wheelHeight)
                .sensoryFeedback(.selection, trigger: selection)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.22),
                            .init(color: .black, location: 0.78),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay {
                    Rectangle().fill(Palette.hairlineStrong).frame(height: 1)
                        .offset(y: -rowHeight / 2)
                    Rectangle().fill(Palette.hairlineStrong).frame(height: 1)
                        .offset(y: rowHeight / 2)
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }

        @ViewBuilder private func optionRow(_ option: String, isCentered: Bool) -> some View {
            let row = label(option, isCentered: isCentered)
                .foregroundStyle(isCentered ? Palette.accent : Palette.muted.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
                .id(option)
            if let onDeleteOption {
                row
                    .contextMenu {
                        Button(role: .destructive) {
                            onDeleteOption(option)
                        } label: {
                            Label("Delete LUT", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: Text("Delete \(option)")) {
                        onDeleteOption(option)
                    }
            } else {
                row
            }
        }

        @ViewBuilder private func label(_ option: String, isCentered: Bool) -> some View {
            let text = Text(option)
                .font(
                    .system(
                        size: isCentered ? 30 : 23,
                        weight: isCentered ? .semibold : .regular,
                        design: .monospaced)
                )
                // Long values shrink to fit the row rather than truncating.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if markedValues.contains(option) {
                HStack(spacing: 6) {
                    text
                    Image(systemName: "star.fill")
                        .font(.system(size: isCentered ? 13 : 10))
                        .opacity(0.85)
                }
            } else {
                text
            }
        }
    }
#endif
