#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import SwiftUI

    /// Complete popup and preparation presentation. Native exporter/account/route operations are
    /// bounded services of the preparation model, never a supplied whole page.
    public struct MonitorOperatorDeliveryScreen<
        Curve: Equatable & Sendable, Format: Equatable & Sendable,
        Project: Sendable, Context: Sendable, Lease: Sendable, Artwork: View
    >: View {
        private let model: MonitorDeliveryPreparationModel<Curve, Format, Project, Context, Lease>
        private let maxCardHeight: CGFloat
        private let onClose: () -> Void
        private let onBegin: (MonitorDeliveryPreparedRequest<Curve, Format, Project, Context, Lease>) -> Void
        private let remoteArtwork: () -> Artwork
        public init(
            model: MonitorDeliveryPreparationModel<Curve, Format, Project, Context, Lease>,
            maxCardHeight: CGFloat = 520, onClose: @escaping () -> Void,
            onBegin: @escaping (MonitorDeliveryPreparedRequest<Curve, Format, Project, Context, Lease>) -> Void,
            @ViewBuilder remoteArtwork: @escaping () -> Artwork
        ) {
            self.model = model
            self.maxCardHeight = maxCardHeight
            self.onClose = onClose
            self.onBegin = onBegin
            self.remoteArtwork = remoteArtwork
        }
        public var body: some View {
            @Bindable var model = model
            MonitorMediaDeliveryPanel(value: value, maxCardHeight: maxCardHeight, action: handle) {
                id in
                if id == MonitorDeliveryDestination.remoteUpload.rawValue {
                    remoteArtwork().foregroundStyle(
                        model.remoteFacts?.configured == true
                            ? MonitorTheme.text : MonitorTheme.faint)
                } else {
                    MonitorIcon.share.frame(width: 18, height: 18).foregroundStyle(
                        MonitorTheme.text)
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.close() }
            .alert("New \(serviceName) project", isPresented: $model.showCreateProject) {
                TextField("Project name", text: $model.newProjectName)
                Button("Cancel", role: .cancel) { model.newProjectName = "" }
                Button("Create") { model.createProject() }
                    .disabled(
                        model.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            } message: {
                Text("Creates a blank project in your workspace.")
            }
            .alert("Leave camera Wi‑Fi?", isPresented: $model.showHopConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Hop") { model.hopToInternet() }
            } message: {
                Text(
                    "We'll hop to home Wi‑Fi or cellular so you can sign in and pick a project. The camera reconnects automatically when you're done."
                )
            }
        }
        private var serviceName: String {
            model.remotePresentation?.displayName ?? "Upload service"
        }
        private var value: MonitorMediaDeliveryValue {
            typealias Value = MonitorMediaDeliveryValue
            let selection = model.selection
            let remote = model.remoteFacts
            let configuration = model.configuration
            let exportOptions = model.clipExportOptions
            var notices: [Value.Notice] = []
            if let cached = selection.cachedCount, cached < selection.files.count {
                let missing = selection.files.count - cached
                if selection.connected == true {
                    notices.append(
                        .init("\(missing) on-camera clip(s) will be cached from the camera first."))
                } else if selection.connected == false {
                    notices.append(
                        .init(
                            "\(missing) on-camera clip(s) will be skipped; reconnect the camera to cache them."
                        ))
                }
            }
            if model.destination == .remoteUpload, remote?.configured == false {
                notices.append(
                    .init(
                        "\(serviceName) isn't configured; add credentials in Settings → Storage.",
                        accented: true))
            } else if model.destination == .remoteUpload, model.step == .options,
                let name = model.selectedProject?.name ?? remote?.savedProjectName
            {
                notices.append(.init("Project: \(name)"))
            }
            let service: Value.Service?
            if model.destination != .remoteUpload {
                service = nil
            } else if model.internetGate {
                let message =
                    (remote?.savedProjectName).map {
                        "\(serviceName) needs the internet. Hop off the camera's Wi-Fi to pick a project (currently “\($0)”) and upload; the camera reconnects automatically when you're done."
                    }
                    ?? "\(serviceName) needs the internet. Hop off the camera's Wi-Fi to sign in and pick a project; the camera reconnects automatically when you're done."
                service = .internetGate(
                    heading: serviceName.uppercased(), message: message, busy: model.hopping)
            } else {
                service = .projects(
                    heading: "PROJECT",
                    help: "Upload destination in your \(serviceName) workspace.",
                    signInNotice: remote?.connected == false
                        ? "Sign in to \(serviceName) from Settings → Storage to upload." : nil,
                    loading: model.projectsLoading, error: model.projectsError,
                    choices: model.listing == nil
                        ? nil : model.uploadableProjects.map { .init(id: $0.id, label: $0.name) },
                    selectedID: model.selectedProjectID, selectedLabel: remote?.savedProjectName)
            }
            var export: Value.Export?
            if !model.internetGate, let configuration, let options = exportOptions {
                let lut = options.lutAvailable()
                let convert = options.convertLogAvailable()
                let exposure = options.bakeExposureAvailable()
                export = .init(
                    filename: options.filename(configuration),
                    convertLog: convert.map {
                        .init(
                            "Convert log",
                            help: $0 ? options.convertHelp : options.convertUnavailableHelp,
                            isOn: configuration.convertLog, enabled: $0)
                    },
                    outputCurve: configuration.convertLog
                        ? .init(
                            "Output curve",
                            options: options.curves.map { .init(id: $0.id, label: $0.label) },
                            selectedID: options.curves.first {
                                $0.value == configuration.logTransform
                            }?.id) : nil,
                    bakeLUT: .init(
                        "Bake LUT",
                        help: lut == true
                            ? options.lutLabel().map { "Apply \($0) to exports." }
                                ?? "Apply the selected LUT to exports."
                            : "No LUT selected. Pick one in view assists.",
                        isOn: configuration.bakeLUT, enabled: lut == true),
                    bakeExposure: configuration.bakeLUT && exposure != nil
                        ? .init(
                            "Bake exposure",
                            help:
                                "Write the LUT exposure pull into the file so it matches the monitor. Off bakes the cube at 0.0.",
                            isOn: configuration.bakeLUTExposure,
                            enabled: lut == true && exposure == true) : nil,
                    format: (configuration.bakeLUT || configuration.convertLog
                        || model.destination == .nativeShare)
                        && (model.destination != .remoteUpload
                            || options.formatsForRemoteUpload == true)
                        ? .init(
                            "Format", help: "MOV preserves quality; MP4 is more widely compatible.",
                            options: options.formats.map { .init(id: $0.id, label: $0.label) },
                            selectedID: options.formats.first {
                                $0.value == configuration.exportFormat
                            }?.id) : nil,
                    includeMetadata: .init(
                        "Include metadata",
                        help: "Filename, capture date, and size (best-effort JSON sidecar).",
                        isOn: configuration.includeMetadata),
                    reupload: model.offersReupload
                        ? .init(
                            "Re-upload already uploaded",
                            help: "Skip clips already on \(serviceName) unless enabled.",
                            isOn: configuration.forceReupload) : nil)
            } else if !model.internetGate, model.step == .options, selection.files.count == 1 {
                export = .init(filename: selection.files.first?.filename)
            }
            let footer: Value.Footer? =
                model.step == .options && !model.internetGate
                ? .init(
                    summary: configuration.map { _ in summary },
                    postExport: model.destination == .nativeShare
                        ? .init(
                            "",
                            options: [
                                .init(
                                    id: MonitorDeliveryPostExportAction.systemShare.rawValue,
                                    label: "Share"),
                                .init(
                                    id: MonitorDeliveryPostExportAction.saveToPhotos.rawValue,
                                    label: "Save to Photos"),
                            ], selectedID: model.action.rawValue) : nil,
                    actionTitle: model.destination == .nativeShare && model.action == .saveToPhotos
                        ? "Save to Photos" : model.destination?.actionTitle ?? "Continue",
                    enabled: model.canContinue) : nil
            return .init(
                step: model.step == .destination ? .destination : .options,
                title: model.destination?.title(
                    remoteDisplayName: model.remotePresentation?.displayName) ?? "Share",
                selectionLabel:
                    "\(selection.files.count) clip\(selection.files.count == 1 ? "" : "s")",
                notices: notices,
                destinations: [MonitorDeliveryDestination.nativeShare, .remoteUpload].compactMap {
                    candidate in
                    if candidate == .remoteUpload && remote == nil { return nil }
                    return .init(
                        id: candidate.rawValue,
                        title: candidate.title(
                            remoteDisplayName: model.remotePresentation?.displayName),
                        subtitle: candidate == .remoteUpload && remote?.configured == true
                            && remote?.connected == false
                            ? "Sign in from Settings → Storage first."
                            : candidate.subtitle(
                                remoteDisplayName: model.remotePresentation?.displayName),
                        enabled: model.destinationEnabled(candidate))
                },
                upcoming: [
                    "Google Drive", "Dropbox", "NAS (SMB)", "LucidLink", "Backblaze B2",
                    "Vimeo Review",
                ],
                service: service, export: export, footer: footer)
        }
        private var summary: String {
            let files = model.selection.files
            let known = files.compactMap(\.sizeBytes)
            let bytes = known.reduce(UInt64(0)) { total, value in
                let sum = total.addingReportingOverflow(value)
                return sum.overflow ? UInt64.max : sum.partialValue
            }
            let size = bytes == 0 ? "0 B" : MediaClipFormatting.byteLabel(bytes)
            let label =
                known.isEmpty
                ? "Size unavailable" : known.count == files.count ? size : "At least \(size)"
            let config = model.configuration
            let mode =
                config?.convertLog == true
                ? model.exportOptions?.curves.first { $0.value == config?.logTransform }?.label
                    ?? "Converted log"
                : config?.bakeLUT == true ? "LUT baked" : "Camera original"
            return "\(files.count) \(files.count == 1 ? "clip" : "clips") · \(label) · \(mode)"
        }
        private func handle(_ action: MonitorMediaDeliveryValue.Action) {
            switch action {
            case .close:
                model.close()
                onClose()
            case .back: model.back()
            case .begin:
                if let request = model.takeRequest() {
                    onClose()
                    onBegin(request)
                }
            case .hopToInternet: model.showHopConfirmation = true
            case .retryProjects: model.loadProjects()
            case .createProject:
                model.newProjectName = ""
                model.showCreateProject = true
            case .destination(let id):
                if let value = MonitorDeliveryDestination(rawValue: id) {
                    model.selectDestination(value)
                }
            case .option(let option, let on):
                switch option {
                case .convertLog: model.setConvertLog(on)
                case .bakeLUT: model.setBakeLUT(on)
                case .bakeExposure: model.configuration?.bakeLUTExposure = on
                case .includeMetadata: model.configuration?.includeMetadata = on
                case .reupload: model.configuration?.forceReupload = on
                }
            case .selection(let selection, let id):
                switch selection {
                case .outputCurve:
                    if let value = model.exportOptions?.curves.first(where: { $0.id == id })?.value
                    {
                        model.configuration?.logTransform = value
                    }
                case .format:
                    if let value = model.exportOptions?.formats.first(where: { $0.id == id })?.value
                    {
                        model.configuration?.exportFormat = value
                    }
                case .postExport:
                    if let value = MonitorDeliveryPostExportAction(rawValue: id) {
                        model.action = value
                    }
                case .project: model.selectProject(id)
                }
            }
        }
    }

    public struct MonitorOperatorDeliveryPopupOverlay<
        Curve: Equatable & Sendable, Format: Equatable & Sendable,
        Project: Sendable, Context: Sendable, Lease: Sendable, Artwork: View
    >: View {
        private let model: MonitorDeliveryPreparationModel<Curve, Format, Project, Context, Lease>
        private let onDismiss: () -> Void
        private let onBegin: (MonitorDeliveryPreparedRequest<Curve, Format, Project, Context, Lease>) -> Void
        private let remoteArtwork: () -> Artwork
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        public init(
            model: MonitorDeliveryPreparationModel<Curve, Format, Project, Context, Lease>,
            onDismiss: @escaping () -> Void,
            onBegin: @escaping (MonitorDeliveryPreparedRequest<Curve, Format, Project, Context, Lease>) -> Void,
            @ViewBuilder remoteArtwork: @escaping () -> Artwork
        ) {
            self.model = model
            self.onDismiss = onDismiss
            self.onBegin = onBegin
            self.remoteArtwork = remoteArtwork
        }
        public var body: some View {
            GeometryReader { geo in
                let safeArea = OperatorPanelMetrics.resolvedDeviceSafeArea(
                    geo.safeAreaInsets, window: windowGeometry.safeArea)
                let cap = max(
                    0,
                    min(
                        geo.size.height * 0.86,
                        geo.size.height - safeArea.top - safeArea.bottom - 20))
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.42).ignoresSafeArea().onTapGesture {
                        model.close()
                        onDismiss()
                    }
                    MonitorOperatorDeliveryScreen(
                        model: model, maxCardHeight: cap, onClose: onDismiss, onBegin: onBegin,
                        remoteArtwork: remoteArtwork
                    )
                    .padding(.leading, safeArea.leading + 12).padding(
                        .trailing, safeArea.trailing + 12
                    )
                    .padding(.bottom, safeArea.bottom + 10)
                }.frame(width: geo.size.width, height: geo.size.height)
            }.ignoresSafeArea()
        }
    }

    /// The delivery popup of one selection (A2-74). The preparation model and its begin action
    /// are made once per `selectionID`, on first display, never by a parent's re-render; a new
    /// selection makes a new pair and the old model closes when its popup leaves. `make` returns
    /// nil when the selection's source is gone, which dismisses the popup.
    public struct MonitorOperatorDeliveryPopupHost<
        Curve: Equatable & Sendable, Format: Equatable & Sendable,
        Project: Sendable, Context: Sendable, Lease: Sendable, Artwork: View
    >: View {
        public typealias Preparation = MonitorDeliveryPreparationModel<
            Curve, Format, Project, Context, Lease
        >
        public typealias Made = (model: Preparation, begin: (Preparation.Request) -> Void)
        private let selectionID: AnyHashable
        private let make: @MainActor () -> Made?
        private let onDismiss: () -> Void
        private let remoteArtwork: () -> Artwork
        public init(
            selectionID: AnyHashable, make: @escaping @MainActor () -> Made?,
            onDismiss: @escaping () -> Void, @ViewBuilder remoteArtwork: @escaping () -> Artwork
        ) {
            self.selectionID = selectionID
            self.make = make
            self.onDismiss = onDismiss
            self.remoteArtwork = remoteArtwork
        }
        public var body: some View {
            MonitorOperatorDeliveryPopupBody(make: make, onDismiss: onDismiss, remoteArtwork: remoteArtwork)
                .id(selectionID)
        }
    }

    @MainActor private final class MonitorDeliveryLazyPreparation<Made> {
        private let make: @MainActor () -> Made?
        lazy var made: Made? = make()
        init(_ make: @escaping @MainActor () -> Made?) { self.make = make }
    }

    private struct MonitorOperatorDeliveryPopupBody<
        Curve: Equatable & Sendable, Format: Equatable & Sendable,
        Project: Sendable, Context: Sendable, Lease: Sendable, Artwork: View
    >: View {
        typealias Host = MonitorOperatorDeliveryPopupHost<Curve, Format, Project, Context, Lease, Artwork>
        // Building the holder is cheap and never calls `make`; SwiftUI keeps the first one.
        @State private var lazy: MonitorDeliveryLazyPreparation<Host.Made>
        private let onDismiss: () -> Void
        private let remoteArtwork: () -> Artwork
        init(
            make: @escaping @MainActor () -> Host.Made?, onDismiss: @escaping () -> Void,
            remoteArtwork: @escaping () -> Artwork
        ) {
            _lazy = State(wrappedValue: MonitorDeliveryLazyPreparation(make))
            self.onDismiss = onDismiss
            self.remoteArtwork = remoteArtwork
        }
        var body: some View {
            if let made = lazy.made {
                MonitorOperatorDeliveryPopupOverlay(
                    model: made.model, onDismiss: onDismiss, onBegin: made.begin,
                    remoteArtwork: remoteArtwork)
            } else {
                // The selection's source is gone: there is nothing to deliver, so leave.
                Color.clear.onAppear(perform: onDismiss)
            }
        }
    }
#endif
