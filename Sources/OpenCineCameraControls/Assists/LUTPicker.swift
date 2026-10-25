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
            "Photo live view is Rec.709. Log conversions are off"
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

    /// One tab of the shared LUT picker, supplied by the app as a value: its official looks, a
    /// library the operator downloaded from a vendor (RED's IPP2 presets on Z) or imported cubes.
    public struct LUTPickerLibrary {
        /// One look; `title` is what its drum row or file row shows.
        public struct Entry: Hashable, Sendable {
            public let id: String
            public let title: String

            public init(id: String, title: String) {
                self.id = id
                self.title = title
            }
        }

        /// A drum of looks, or the imported-file list under an import button.
        public enum Layout: Sendable {
            case drum
            case files
        }

        /// A choice row in the caption slot that narrows the drum (RED's output colour space).
        public struct Filter {
            public let options: [String]
            public let selection: Binding<String>

            public init(options: [String], selection: Binding<String>) {
                self.options = options
                self.selection = selection
            }
        }

        /// A button the picker shows under an empty library (a vendor download).
        public struct Action {
            public let title: String
            public let systemImage: String
            public let perform: () -> Void

            public init(title: String, systemImage: String, perform: @escaping () -> Void) {
                self.title = title
                self.systemImage = systemImage
                self.perform = perform
            }
        }

        /// What an empty library shows: why it is empty and, optionally, how to fill it.
        public struct Empty {
            public let title: String?
            public let hint: String
            public let action: Action?

            public init(title: String? = nil, hint: String, action: Action? = nil) {
                self.title = title
                self.hint = hint
                self.action = action
            }
        }

        public let title: String
        public let layout: Layout
        public let entries: [Entry]
        /// The applied look belongs here, so the picker opens on this tab.
        public let isCurrent: Bool
        /// The applied entry, when this library lists it.
        public let selectedID: String?
        /// The look a switch to this tab applies while another tab's look is current; the drum
        /// rests on it until one of this library's looks is applied.
        public let representative: Entry?
        public let caption: String
        public let filter: Filter?
        /// Looks flagged with a star (a recommended default).
        public let markedIDs: Set<String>
        /// False shows the drum for reference only.
        public let allowsSelection: Bool
        public let empty: Empty?
        public let select: (Entry) -> Void
        /// Removes a stored look; the picker confirms first and reports a failure.
        public let delete: ((Entry) throws -> Void)?
        /// Imports a picked `.cube`; the picker holds the file's security scope around it.
        public let importCube: ((URL) throws -> Void)?

        public init(
            title: String, layout: Layout = .drum, entries: [Entry], isCurrent: Bool,
            selectedID: String?, representative: Entry? = nil, caption: String = "",
            filter: Filter? = nil, markedIDs: Set<String> = [], allowsSelection: Bool = true,
            empty: Empty? = nil, select: @escaping (Entry) -> Void,
            delete: ((Entry) throws -> Void)? = nil, importCube: ((URL) throws -> Void)? = nil
        ) {
            self.title = title
            self.layout = layout
            self.entries = entries
            self.isCurrent = isCurrent
            self.selectedID = selectedID
            self.representative = representative
            self.caption = caption
            self.filter = filter
            self.markedIDs = markedIDs
            self.allowsSelection = allowsSelection
            self.empty = empty
            self.select = select
            self.delete = delete
            self.importCube = importCube
        }

        /// The drum row: the applied look, else the representative, else the first look.
        public var drumTitle: String {
            let selected = selectedID.flatMap { id in entries.first { $0.id == id } }
            return (selected ?? representative ?? entries.first)?.title ?? ""
        }

        /// The look a drum row names. The first wins when short names collide.
        public func entry(titled title: String) -> Entry? {
            entries.first { $0.title == title }
        }

        public var markedTitles: Set<String> {
            Set(entries.filter { markedIDs.contains($0.id) }.map(\.title))
        }
    }

    /// The shared LUT picker over any look provider: the app's libraries as tabs, the drum or file
    /// list of the open tab and, in the sheet form, the look comparison under it. `embedded` is
    /// the assist inspector form, whose footer already pins the comparison (A1-37).
    public struct MonitorLUTPickerView<Looks: MonitorLookProvider, Palette: LiveChromePalette, Footer: View>: View {
        private struct PendingDeletion {
            let library: String
            let entry: LUTPickerLibrary.Entry
        }

        let assist: MonitorAssistState<Looks>
        let embedded: Bool
        let haptics: OperatorHaptics
        let preparation: AnyHashable
        let prepare: () -> Void
        let libraries: () -> [LUTPickerLibrary]
        let footer: Footer
        @Environment(\.dismiss) private var dismiss
        @State private var tab: String?
        @State private var importing = false
        /// The library the open file importer adds to.
        @State private var importTarget: String?
        @State private var pendingDeletion: PendingDeletion?
        @State private var deletionErrorMessage: String?
        @State private var importError: String?

        /// The reference monitor's drum height: landscape has no headroom for a taller drum.
        private let contentHeight: CGFloat = 146
        private let captionHeight: CGFloat = 28
        private let actionHeight: CGFloat = 44

        /// `prepare` runs on appear and whenever `preparation` changes (the app's refresh of its
        /// libraries or of the session its looks follow).
        public init(
            assist: MonitorAssistState<Looks>, embedded: Bool = false, haptics: OperatorHaptics,
            palette _: Palette.Type, preparation: AnyHashable = 0,
            prepare: @escaping () -> Void = {},
            libraries: @escaping () -> [LUTPickerLibrary],
            @ViewBuilder footer: () -> Footer
        ) {
            self.assist = assist
            self.embedded = embedded
            self.haptics = haptics
            self.preparation = preparation
            self.prepare = prepare
            self.libraries = libraries
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

        private func open(_ libraries: [LUTPickerLibrary]) -> LUTPickerLibrary? {
            libraries.first { $0.title == tab } ?? libraries.first { $0.isCurrent } ?? libraries.first
        }

        private var picker: some View {
            let libraries = self.libraries()
            let open = self.open(libraries)
            return VStack(spacing: 8) {
                MonitorCaptureTabs(
                    options: libraries.map(\.title), selection: open?.title, title: { $0 },
                    identifier: { "monitor.lut.tab.\($0)" }
                ) { next in
                    guard next != open?.title,
                        let library = libraries.first(where: { $0.title == next })
                    else { return }
                    tab = next
                    if !library.isCurrent, let look = library.representative {
                        library.select(look)
                    }
                }
                Group {
                    if let open {
                        switch open.layout {
                        case .drum: drum(open)
                        case .files: files(open)
                        }
                    }
                }
                .id(open?.title)
                .frame(maxWidth: .infinity)
                .frame(height: contentHeight)
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
                tab = (libraries.first { $0.isCurrent } ?? libraries.first)?.title
                prepare()
            }
            .onChange(of: preparation) { _, _ in prepare() }
            .confirmationDialog(
                pendingDeletion.map { "Clear \($0.entry.title)?" } ?? "Clear LUT?",
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
                handleImport(result, into: importTarget)
            }
        }

        @ViewBuilder private func drum(_ library: LUTPickerLibrary) -> some View {
            if library.entries.isEmpty, library.filter == nil, let empty = library.empty {
                VStack(spacing: 8) {
                    placeholder(empty)
                    if let action = empty.action {
                        actionButton(action)
                            .frame(height: actionHeight)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    if let filter = library.filter {
                        filterRow(filter)
                            .frame(height: captionHeight)
                    } else {
                        Text(library.caption)
                            .font(MonitorTheme.font(11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .frame(height: captionHeight)
                    }
                    LUTDrumWheel<Palette>(
                        options: library.entries.map(\.title),
                        selection: Binding(
                            get: { library.drumTitle },
                            set: { title in
                                // A reference-only catalogue must not overwrite the saved look
                                // when scrollPosition reports its displayed row on mount.
                                guard library.allowsSelection,
                                    let entry = library.entry(titled: title)
                                else { return }
                                library.select(entry)
                            }
                        ),
                        markedValues: library.markedTitles,
                        wheelHeight: contentHeight - captionHeight - 4,
                        onDeleteOption: library.delete == nil
                            ? nil
                            : { (title: String) in
                                guard let entry = library.entry(titled: title) else { return }
                                pendingDeletion = PendingDeletion(library: library.title, entry: entry)
                            }
                    )
                }
            }
        }

        private func files(_ library: LUTPickerLibrary) -> some View {
            VStack(spacing: 6) {
                if library.importCube != nil {
                    Button {
                        importTarget = library.title
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
                }
                if library.entries.isEmpty {
                    Text(library.empty?.hint ?? "")
                        .font(MonitorTheme.font(11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(library.entries, id: \.id) { entry in
                                fileRow(entry, in: library)
                            }
                        }
                    }
                    .monitorScrollFade()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        private func fileRow(_ entry: LUTPickerLibrary.Entry, in library: LUTPickerLibrary)
            -> some View
        {
            let selected = library.selectedID == entry.id
            return HStack(spacing: 6) {
                Button {
                    library.select(entry)
                } label: {
                    Text(entry.title)
                        .font(MonitorTheme.font(13, weight: .semibold))
                        .foregroundStyle(selected ? Palette.accent : Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.monitorTapTarget)
                if library.delete != nil {
                    Button {
                        pendingDeletion = PendingDeletion(library: library.title, entry: entry)
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
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Palette.accentDim : Palette.glassBright,
                in: RoundedRectangle(cornerRadius: Palette.cornerRadius, style: .continuous)
            )
        }

        private func filterRow(_ filter: LUTPickerLibrary.Filter) -> some View {
            HStack(spacing: 6) {
                ForEach(filter.options, id: \.self) { option in
                    let isOn = filter.selection.wrappedValue == option
                    Button {
                        filter.selection.wrappedValue = option
                    } label: {
                        Text(option)
                            .font(MonitorTheme.font(12, weight: .semibold))
                            .foregroundStyle(isOn ? Palette.accent : Palette.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isOn ? Palette.accentDim : Palette.glassBright, in: Capsule())
                    }
                    .buttonStyle(.monitorTapTarget)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        }

        private func placeholder(_ empty: LUTPickerLibrary.Empty) -> some View {
            VStack(spacing: 6) {
                if let title = empty.title {
                    Text(title)
                        .font(MonitorTheme.font(14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                }
                Text(empty.hint)
                    .font(MonitorTheme.font(12, weight: .regular))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func actionButton(_ action: LUTPickerLibrary.Action) -> some View {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.systemImage)
                    .font(MonitorTheme.font(13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.glassBright, in: Capsule())
            }
            .buttonStyle(.monitorTapTarget)
        }

        private func handleImport(_ result: Result<URL, Error>, into library: String?) {
            switch result {
            case .success(let url):
                guard let importCube = libraries().first(where: { $0.title == library })?.importCube
                else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    try importCube(url)
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }

        private func clear(_ pending: PendingDeletion) {
            pendingDeletion = nil
            guard let delete = libraries().first(where: { $0.title == pending.library })?.delete
            else { return }
            do {
                try delete(pending.entry)
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    extension MonitorLUTPickerView where Footer == MonitorOperatorLookComparison<Looks> {
        /// The shared comparison is the sheet footer; embedded callers supply it once in the inspector.
        public init(
            assist: MonitorAssistState<Looks>, embedded: Bool = false, haptics: OperatorHaptics,
            palette: Palette.Type, preparation: AnyHashable = 0,
            prepare: @escaping () -> Void = {}, libraries: @escaping () -> [LUTPickerLibrary]
        ) {
            self.init(assist: assist, embedded: embedded, haptics: haptics, palette: palette,
                preparation: preparation, prepare: prepare, libraries: libraries) {
                MonitorOperatorLookComparison(assist: assist, haptics: haptics, exposure: .provider)
            }
        }
    }

    extension MonitorLUTPickerView where Looks == MonitorLUTLooks, Footer == MonitorOperatorLookComparison<Looks> {
        /// Official / Creative / Custom on the camera session in `context`, which Auto follows.
        public init(
            assist: MonitorAssistState<MonitorLUTLooks>, embedded: Bool = false,
            context: LUTPickerContext, copy: LUTPickerCopy, haptics: OperatorHaptics,
            palette: Palette.Type
        ) {
            self.init(
                assist: assist, embedded: embedded, haptics: haptics, palette: palette,
                preparation: AnyHashable([AnyHashable(context.isPhoto), AnyHashable(context.colorMode)]),
                prepare: {
                    assist.bindLUTPicker(
                        live: context.colorMode,
                        inPlayback: context.inPlayback,
                        family: context.family,
                        cameraName: context.cameraName,
                        lookProfile: context.lookProfile,
                        isPhoto: context.isPhoto,
                        isWatching: context.isWatching)
                },
                libraries: { assist.lutPickerLibraries(context: context, copy: copy) })
        }
    }

    /// The original two-parameter picker API, retained while hosts adopt typed libraries.
    /// Its caller-supplied footer retains the original sheet behavior.
    public struct LUTPickerView<Palette: LiveChromePalette, Footer: View>: View {
        private let picker: MonitorLUTPickerView<MonitorLUTLooks, Palette, Footer>

        public init(
            assist: MonitorAssistState<MonitorLUTLooks>, embedded: Bool = false,
            context: LUTPickerContext, copy: LUTPickerCopy, palette: Palette.Type,
            @ViewBuilder footer: () -> Footer
        ) {
            picker = MonitorLUTPickerView(
                assist: assist, embedded: embedded, haptics: OperatorHaptics(isEnabled: { false }),
                palette: palette,
                preparation: AnyHashable([AnyHashable(context.isPhoto), AnyHashable(context.colorMode)]),
                prepare: {
                    assist.bindLUTPicker(
                        live: context.colorMode, inPlayback: context.inPlayback,
                        family: context.family, cameraName: context.cameraName,
                        lookProfile: context.lookProfile, isPhoto: context.isPhoto,
                        isWatching: context.isWatching)
                },
                libraries: { assist.lutPickerLibraries(context: context, copy: copy) },
                footer: footer)
        }

        public var body: some View { picker }
    }

    extension MonitorAssistState where Looks == MonitorLUTLooks {
        /// The official catalogue, the creative looks and the imported files as picker tabs.
        func lutPickerLibraries(context: LUTPickerContext, copy: LUTPickerCopy) -> [LUTPickerLibrary] {
            let livePhoto =
                context.isPhoto && !context.inPlayback && !gradesClip && !context.isWatching
            let catalog = looks.official.catalog(livePhoto)
            let selection = lutSelection
            let select: (LUTPickerLibrary.Entry) -> Void = { [self] entry in
                if let look = LUTSelection(rawValue: entry.id) { selectLUT(look) }
            }
            return [
                LUTPickerLibrary(
                    title: copy.officialTab, entries: catalog.map(\.pickerEntry),
                    isCurrent: selection.isOfficial,
                    selectedID: selection.isOfficial && catalog.contains(selection)
                        ? selection.rawValue : nil,
                    representative: LUTSelection.officialAuto.pickerEntry,
                    caption: officialCaption(livePhoto: livePhoto, copy: copy),
                    allowsSelection: !livePhoto, select: select),
                LUTPickerLibrary(
                    title: "Creative", entries: LUTSelection.creativeCases.map(\.pickerEntry),
                    isCurrent: selection.isCreative,
                    selectedID: selection.isCreative ? selection.rawValue : nil,
                    representative: LUTSelection.creativeMono.pickerEntry,
                    caption: selection.isCreative
                        ? LUTResolver.autoCaption(source: resolvedSource())
                        : "Looks for the displayed picture",
                    select: select),
                LUTPickerLibrary(
                    title: "Custom", layout: .files,
                    entries: looks.customLUTs.list().map {
                        LUTPickerLibrary.Entry(id: $0.fileName, title: $0.displayName)
                    },
                    isCurrent: selection.isCustom,
                    selectedID: selection == .customFile
                        ? looks.preferences.selectedCustomFileName : nil,
                    empty: .init(hint: copy.customEmptyHint),
                    select: { [self] in selectCustomFile($0.id) },
                    delete: { [self] in clearCustomFile($0.id) },
                    importCube: { [self] in try importCustomCube(from: $0) }),
            ]
        }

        private func officialCaption(livePhoto: Bool, copy: LUTPickerCopy) -> String {
            if livePhoto { return LUTPickerCopy.photoRec709Caption }
            if lutSelection == .officialAuto || lutSelection == .auto {
                return LUTResolver.autoCaption(source: resolvedSource())
            }
            return lutSelection.isOfficial ? copy.officialLockedCaption : copy.officialCaption
        }

        private func importCustomCube(from url: URL) throws {
            let store = looks.customLUTs
            let stored = try store.importFile(from: url)
            guard store.cube(stored) != nil else {
                try? store.remove(stored)
                throw CustomLUTStoreError.unreadable
            }
            importCustom(fileName: stored.fileName)
        }
    }

    extension LUTSelection {
        fileprivate var pickerEntry: LUTPickerLibrary.Entry {
            LUTPickerLibrary.Entry(id: rawValue, title: title)
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
