#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia
import SwiftUI
import UIKit

/// What a still's view assists use from the app: panel stores, false colour looks, palette,
/// the tool usage order and the playback page options. The photo page offers the playback bar's
/// tools that apply to a still (`MonitorAssistSelection.photoToolbarCases`); scopes need stores.
@MainActor public struct MonitorPhotoAssistTools<Looks: MonitorLookProvider> {
    struct Inspection {
        let tool: MonitorAssistSelection
        let assist: MonitorAssistState<Looks>
        let haptics: OperatorHaptics
        let viewport: CGSize
        let safeArea: EdgeInsets
        let available: Set<MonitorAssistSelection>
        let onDismiss: () -> Void
        let preview: (MonitorAssistSelection) -> AnyView
    }
    let stores: AssistPanelStores?
    let looks: FalseColorLooks
    let usage: Binding<MonitorToolUsage>?
    let availableAssistTools: Set<MonitorAssistSelection>?
    let signalOptions: MonitorOperatorSignalOptions
    let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    let inspector: @MainActor (Inspection) -> AnyView

    /// `availableAssistTools` narrows the still's tools as it narrows playback's (nil: all of them).
    public init<Palette: LiveChromePalette>(stores: AssistPanelStores?, looks: FalseColorLooks,
        palette: Palette.Type, usage: Binding<MonitorToolUsage>?,
        availableAssistTools: Set<MonitorAssistSelection>? = nil,
        signalOptions: MonitorOperatorSignalOptions = .init(),
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr }) {
        self.stores = stores; self.looks = looks; self.usage = usage
        self.availableAssistTools = availableAssistTools; self.signalOptions = signalOptions
        self.configureDisplay = configureDisplay
        inspector = { value in
            AnyView(MonitorOperatorAssistInspector(tool: value.tool, assist: value.assist, stores: stores,
                looks: looks, palette: Palette.self, haptics: value.haptics, sourceTransfer: .rec709,
                clipByte: MonitorPhotoAssistTools.clipByte, viewport: value.viewport, safeArea: value.safeArea,
                available: value.available, signalOptions: signalOptions, onDismiss: value.onDismiss,
                preview: value.preview, lookMenu: { EmptyView() }))
        }
    }

    /// The same values the app's playback page uses.
    public init<Host: MonitorMediaHost, Palette: LiveChromePalette>(host: Host,
        values: MonitorMediaPageValues<Palette>, options: MonitorPlaybackPageOptions = .init())
    where Host.Looks == Looks {
        self.init(stores: values.stores, looks: values.looks, palette: Palette.self,
            usage: Binding(get: { host.assistToolUsage }, set: { host.assistToolUsage = $0 }),
            availableAssistTools: options.availableAssistTools, signalOptions: options.signalOptions,
            configureDisplay: values.configureDisplay)
    }

    /// A page given no app values: no panel stores (so no scopes), the signal's false colour help
    /// and the shared default palette; the tool order lives with the page.
    static var standard: Self {
        .init(stores: nil, looks: .signal, palette: MonitorDefaultLivePalette.self, usage: nil)
    }
    /// A still is display-referred Rec.709 with full-range codes.
    static var transfer: MonitorTransfer { .rec709 }
    static var clipByte: Int { 255 }
}

/// Common still-picture presentation. The only view port draws one decoded native image.
public struct MonitorOperatorPhotoScreen<Payload: Sendable, Looks: MonitorLookProvider>: View {
    private let loaders: MonitorMediaPictureLoaders<Payload, UIImage>
    private let policy: MonitorMediaPictureLoadPolicy
    private let operations: MonitorMediaGalleryOperations<Payload>
    private let assist: MonitorAssistState<Looks>
    private let haptics: OperatorHaptics
    private let coverPresented: Bool
    private let rating: MonitorMediaPictureRatingService<Payload>?
    private let sharing: MonitorMediaPictureSharing<Payload>?
    private let collection: [MonitorMediaRecord<Payload>]
    private let bottomAccessoryInset: CGFloat
    private let selectRecord: (@MainActor (MonitorMediaRecord<Payload>) -> Void)?
    private let collectionThumbnail: (@MainActor (MonitorMediaPictureRequest<Payload>) -> AnyView)?
    private let close: @MainActor () -> Void
    private let deleted: @MainActor () -> Void
    private let deletedReturning: (@MainActor (MonitorMediaLibraryActionToken) -> Void)?
    private let share: (@MainActor (MonitorMediaPictureRequest<Payload>) -> Void)?
    private let tools: MonitorPhotoAssistTools<Looks>
    @State private var activated = false
    @State private var model: MonitorMediaPictureModel<Payload, UIImage>
    @State private var assistExpanded = false
    @State private var pageUsage = MonitorToolUsage()
    @State private var toolbarFrame = CGRect.zero
    @State private var renderer = MonitorStillLookRenderer()
    @State private var look: MonitorStillLook?
    @State private var scopes: MonitorStillScopes?
    @Environment(\.monitorWindowGeometry) private var windowGeometry

    public init(library: MonitorMediaLibraryModel<Payload>, record: MonitorMediaRecord<Payload>,
        admission: MonitorMediaLibraryActionToken? = nil, assist: MonitorAssistState<Looks>,
        loaders: MonitorMediaPictureLoaders<Payload, UIImage>,
        policy: MonitorMediaPictureLoadPolicy = .previewThenOriginal,
        operations: MonitorMediaGalleryOperations<Payload> = .init(), haptics: OperatorHaptics = .init(isEnabled: { false }),
        coverPresented: Bool = false,
        variants: [MonitorMediaPictureVariant<Payload>] = [],
        rating: MonitorMediaPictureRatingService<Payload>? = nil,
        sharing: MonitorMediaPictureSharing<Payload>? = nil, collection: [MonitorMediaRecord<Payload>] = [],
        bottomAccessoryInset: CGFloat = 0,
        selectRecord: (@MainActor (MonitorMediaRecord<Payload>) -> Void)? = nil,
        collectionThumbnail: (@MainActor (MonitorMediaPictureRequest<Payload>) -> AnyView)? = nil,
        sourceCurrent: @escaping @MainActor () -> Bool = { true }, close: @escaping @MainActor () -> Void,
        deleted: (@MainActor () -> Void)? = nil,
        share: (@MainActor (MonitorMediaPictureRequest<Payload>) -> Void)? = nil,
        deletedReturning: (@MainActor (MonitorMediaLibraryActionToken) -> Void)? = nil,
        assistTools: MonitorPhotoAssistTools<Looks>? = nil) {
        self.tools = assistTools ?? .standard
        self.loaders = loaders; self.policy = policy; self.operations = operations
        self.assist = assist; self.haptics = haptics; self.coverPresented = coverPresented; self.close = close; self.share = share
        self.rating = rating; self.sharing = sharing; self.collection = collection
        self.bottomAccessoryInset = bottomAccessoryInset
        self.selectRecord = selectRecord; self.collectionThumbnail = collectionThumbnail
        self.deleted = deleted ?? close
        self.deletedReturning = deletedReturning
        _model = State(initialValue: .init(library: library, record: record, admission: admission, variants: variants, sourceCurrent: sourceCurrent))
    }
    public var body: some View {
        let deleteID = model.deleteRequestID
        Group {
            if activated && !model.isCurrent {
                MonitorOperatorMediaUnavailable(closeEnabled: !model.closing) { model.close(completed: close) }
            } else { photoContent }
        }
        .statusBarHidden().preferredColorScheme(.dark)
        .onAppear {
            model.activate(); activated = true; model.load(loaders, policy: policy); model.readRating(rating)
            assist.configureTool = nil; assist.gradesClip = true
        }
        .onDisappear { model.retire(); assist.configureTool = nil; assist.gradesClip = false }
        .onChange(of: model.record.asset.id) { _, _ in assist.configureTool = nil; assistExpanded = false }
        .onChange(of: coverPresented) { _, covered in if covered { assist.configureTool = nil; assistExpanded = false } }
        .task(id: lookKey) { await renderLook() }
        .task(id: scopeKey) { await sampleScopes() }
        .onChange(of: model.isCurrent) { _, current in if !current && !model.closing { model.sourceChanged() } }
        .onChange(of: model.library.lifetimeToken) { _, _ in model.sourceChanged() }
        .confirmationDialog(model.deletionMessage ?? "Delete this photo from the camera?",
            isPresented: Binding(get: { model.deleteRequestID != nil }, set: { if !$0 { model.cancelDelete(admitted: deleteID) } }),
            titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.confirmDelete(deleteID, operations: operations, completed: finishDeletion) }
                Button("Cancel", role: .cancel) { model.cancelDelete(admitted: deleteID) }
            }
        .overlay(alignment: .bottom) {
            if model.isCurrent, let selectRecord, collection.count > 1 {
                MonitorPhotoFilmstrip(items: collection, selected: model.baseRecord.asset.id, keyOf: { $0.asset.id },
                    enabled: model.isCurrent && !model.closing, label: { $0.asset.filename },
                    select: { model.navigate(to: $0, selected: selectRecord) }) { record in
                        if let request = model.request(for: record.asset.id), let collectionThumbnail {
                            collectionThumbnail(request)
                        } else { Rectangle().fill(MonitorTheme.surface) }
                    }.padding(.bottom, 10)
            }
        }
        // The option panel covers the page as it covers playback.
        .overlay { if model.isCurrent { inspector } }
        .alert("Couldn't share this photo", isPresented: Binding(get: { model.failure != nil },
            set: { if !$0 { model.dismissFailure() } })) {
                Button("OK") { model.dismissFailure() }
            } message: { Text(model.failure ?? "") }
    }
    private var photoContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let picture = model.picture { stage(picture) }
            else if model.loading {
                VStack(spacing: 12) {
                    ProgressView().tint(MonitorTheme.accent)
                    Text("Preparing image…").font(MonitorTheme.font(14, weight: .medium)).foregroundStyle(MonitorTheme.muted)
                }
            }
            VStack {
                HStack(spacing: 10) {
                    Button { back() } label: { icon(.x) }
                        .buttonStyle(.monitorTapTarget).accessibilityLabel("Back to media")
                        .accessibilityIdentifier("monitor.photo.back").disabled(model.closing)
                    Text(model.record.asset.filename).font(MonitorTheme.font(14, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if model.variants.count > 1 { variantChoices }
                    if !collection.isEmpty, model.canDelete(operations) {
                        Button("Delete all") { model.requestDelete(operations, records: collection) }
                            .font(MonitorTheme.font(13, weight: .semibold)).foregroundStyle(.red)
                            .buttonStyle(.monitorTapTarget).accessibilityLabel("Delete the whole burst series")
                    }
                    if model.canDelete(operations) {
                        Button { model.requestDelete(operations) } label: { icon(.trash) }
                            .buttonStyle(.monitorTapTarget).accessibilityLabel("Delete photo")
                    }
                    if let share {
                        Button { model.share(share, sharing: sharing) } label: {
                            if model.preparingShare { ProgressView().tint(MonitorTheme.accent).frame(width: 34, height: 34) }
                            else { icon(.share) }
                        }.disabled(!model.canShare(sharing))
                            .buttonStyle(.monitorTapTarget).accessibilityLabel("Share photo")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14 + windowGeometry.topControlInset)
                Spacer()
                VStack(spacing: 10) {
                    if let message = model.ratingNotice ?? model.status.message {
                        Text(statusMessage(message)).font(MonitorTheme.font(13, weight: .medium)).foregroundStyle(MonitorTheme.text)
                            .padding(.horizontal, 16).padding(.vertical, 10).liquidGlass(in: Capsule()).padding(.horizontal, 24)
                    }
                    HStack(spacing: 20) {
                    if let rating, let stars = model.ratingStars, model.status.showsRating {
                        MonitorStarRating(stars: stars, levels: rating.levels, enabled: model.isCurrent) {
                            haptics.selection(); model.setRating($0, service: rating)
                        }
                    } else if rating == nil || !model.ratingReading {
                    // Favorite is the fallback whenever stars are unavailable (A2-44).
                    Button { model.toggleFavorite(operations) } label: {
                        MonitorIcon.star.view(filled: model.favorite).frame(width: 17, height: 17)
                            .foregroundStyle(model.favorite ? MonitorTheme.accent : MonitorTheme.text)
                            .frame(width: 34, height: 34).liquidGlass(in: Circle(), interactive: true)
                    }.buttonStyle(.monitorTapTarget)
                        .accessibilityLabel(model.favorite ? "Remove from favorites" : "Add to favorites")
                    }
                    }
                }.padding(.bottom, 18 + bottomAccessoryInset + (selectRecord != nil && collection.count > 1 ? 64 : 0))
            }
            if model.isCurrent, !coverPresented, !available.isEmpty { assistBar }
        }
    }
    private func back() {
        if assist.configureTool != nil { assist.configureTool = nil; return }
        if assistExpanded { assistExpanded = false; return }
        if !model.back() { model.close(completed: close) }
    }
    private func finishDeletion() {
        if let deletedReturning, let proof = model.deletionCompletion, proof.removedCount > 0, proof.isCurrent {
            deletedReturning(proof.admission)
        } else if deletedReturning == nil {
            deleted()
        }
    }
    private func statusMessage(_ message: String) -> String {
        model.status.progress.map { "\(message) \(Int($0 * 100))%" } ?? message
    }
    private var variantChoices: some View {
        HStack(spacing: 2) {
            ForEach(model.variants) { choice in
                Button { model.selectVariant(choice.id, loaders: loaders, policy: policy) } label: {
                    Text(choice.label).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(choice.id == model.record.asset.id ? MonitorTheme.accent : MonitorTheme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(choice.id == model.record.asset.id ? MonitorTheme.accent.opacity(0.15) : .clear, in: Capsule())
                }.buttonStyle(.monitorTapTarget).disabled(model.variantSwitching || !model.isCurrent)
                    .accessibilityLabel("Show \(choice.label)")
            }
        }.padding(2).background(.black.opacity(0.35), in: Capsule())
            .accessibilityLabel("Photo format")
    }
    private func icon(_ icon: MonitorIcon) -> some View {
        icon.frame(width: 34 * 0.38, height: 34 * 0.38).foregroundStyle(MonitorTheme.text)
            .frame(width: 34, height: 34).glassCircle(interactive: true)
    }
    // MARK: View assists

    /// The playback bar's tools that apply to this still, narrowed as the app narrows playback.
    private var available: [MonitorAssistSelection] {
        MonitorAssistSelection.photoToolbarCases.filter {
            (tools.availableAssistTools?.contains($0) ?? true)
                && (tools.stores != nil || !MonitorAssistSelection.mediaScopes.contains($0))
        }
    }
    private func hasOptions(_ tool: MonitorAssistSelection) -> Bool {
        MonitorMediaAssistOptions.hasOptions(tool, stores: tools.stores != nil, signalOptions: tools.signalOptions)
    }
    private func shows(_ tool: MonitorAssistSelection) -> Bool {
        assist.isPlaybackVisible(tool) && available.contains(tool)
    }
    private var usage: Binding<MonitorToolUsage> { tools.usage ?? $pageUsage }
    /// The still's own effects: the playback set of shown tools over a Rec.709 picture.
    private var stillEffects: MonitorFrameEffects {
        var value = assist.playbackEffects
        value.transfer = MonitorPhotoAssistTools<Looks>.transfer
        value.clipByte = MonitorPhotoAssistTools<Looks>.clipByte
        value.referenceClipByte = MonitorPhotoAssistTools<Looks>.clipByte
        value.allowsTransferInference = false
        value.lutDimension = 0; value.lutRGBA = Data(); value.splitComparison = false
        value.peaking = shows(.peaking); value.zebra = shows(.zebra); value.falseColor = shows(.falseColor)
        value.mirror = shows(.mirror) && assist.mirrorHorizontal
        value.mirrorVertical = shows(.mirror) && assist.mirrorVertical
        value.desqueezeFactor = shows(.desqueeze) ? assist.desqueezeFactor : 1
        return value
    }
    /// What the painted picture depends on: no scope, geometry or inspector demand.
    private var paintEffects: MonitorFrameEffects {
        var value = stillEffects
        value.histogram = false; value.waveform = false; value.parade = false; value.vectorscope = false
        value.trafficLights = false; value.ndMeter = false; value.evMeter = false; value.inspectorSample = false
        value.desqueezeFactor = 1; value.mirror = false; value.mirrorVertical = false
        return value
    }
    private var lookKey: MonitorStillLook.Key? {
        guard let picture = model.picture else { return nil }
        return .init(picture: ObjectIdentifier(picture), effects: paintEffects)
    }
    private var scopeKey: ObjectIdentifier? {
        guard let picture = model.picture, tools.stores != nil,
            MonitorAssistSelection.mediaScopes.contains(where: shows) else { return nil }
        return ObjectIdentifier(picture)
    }
    private func renderLook() async {
        guard let key = lookKey, let picture = model.picture else { look = nil; return }
        guard MonitorStillLookRenderer.paints(key.effects) else { look = nil; return }
        if look?.key.picture != key.picture { look = nil }
        let painted = await MonitorStillLook.render(picture, effects: key.effects, renderer: renderer)
        guard !Task.isCancelled, lookKey == key else { return }
        look = painted.map { .init(key: key, image: $0) }
    }
    private func sampleScopes() async {
        guard let key = scopeKey, let picture = model.picture else { return }
        if scopes?.picture == key { return }
        let bundle = await MonitorStillScopes.sample(picture)
        guard !Task.isCancelled, scopeKey == key else { return }
        scopes = .init(picture: key, bundle: bundle)
    }
    /// The painted still once it matches the shown picture; the decoded one until then.
    private func displayed(_ picture: UIImage) -> UIImage {
        guard let look, look.key.picture == ObjectIdentifier(picture), MonitorStillLookRenderer.paints(paintEffects)
        else { return picture }
        return look.image
    }

    private func stage(_ picture: UIImage) -> some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let effects = stillEffects
            let rect = DesqueezeAssist.presentationRect(sourceSize: picture.size, in: canvas, effects: effects)
            ZStack(alignment: .topLeading) {
                MonitorInteractivePicture(source: model.presentation, canvas: proxy.size, feed: rect,
                    enabled: model.isCurrent && !coverPresented && assist.configureTool == nil
                        && model.deleteRequestID == nil,
                    accessibilityLabel: "Photo preview for \(model.record.asset.filename)") { _ in
                        Image(uiImage: displayed(picture)).resizable()
                            .scaleEffect(x: effects.mirror ? -1 : 1, y: effects.mirrorVertical ? -1 : 1)
                    }
                MonitorMediaFeedMarks(assist: assist, rect: rect)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if let stores = tools.stores {
                    MonitorMediaSignalOverlays(assist: assist, stores: stores, looks: tools.looks, haptics: haptics,
                        canvas: canvas, feed: rect, tools: available,
                        readScopes: scopes.map { value in { value.bundle } },
                        configureDisplay: tools.configureDisplay, paradeIntensityScale: 1,
                        transfer: MonitorPhotoAssistTools<Looks>.transfer,
                        clipByte: MonitorPhotoAssistTools<Looks>.clipByte, signalOptions: tools.signalOptions,
                        onConfigure: { options($0) })
                }
            }
        }.ignoresSafeArea()
    }
    private var assistBar: some View {
        MonitorMediaToolsStage(expanded: $assistExpanded) { context in
            MonitorMediaAssistBar(assist: assist, tools: available, hasOptions: hasOptions, usage: usage,
                presentation: context.presentation, safeTop: context.safeTop, expanded: context.expanded,
                onFrame: { toolbarFrame = $0 }, onOptions: { options($0) })
        }
    }
    private func options(_ tool: MonitorAssistSelection) {
        guard model.isCurrent, available.contains(tool), hasOptions(tool) else { return }
        assist.longPressAnchorRect = .init(x: toolbarFrame.minX, y: toolbarFrame.minY,
            width: toolbarFrame.width, height: toolbarFrame.height)
        assist.configureTool = tool
    }
    @ViewBuilder private var inspector: some View {
        if let tool = assist.configureTool, available.contains(tool), hasOptions(tool) {
            GeometryReader { proxy in
                tools.inspector(.init(tool: tool, assist: assist, haptics: haptics, viewport: proxy.size,
                    safeArea: OperatorPanelMetrics.resolvedDeviceSafeArea(
                        proxy.safeAreaInsets, window: windowGeometry.safeArea),
                    available: Set(available.filter(hasOptions)),
                    onDismiss: { assist.configureTool = nil },
                    preview: { tool in AnyView(preview(tool)) }))
            }.ignoresSafeArea().zIndex(6)
        }
    }
    /// The still with the inspected tool applied, as playback previews its frame.
    @ViewBuilder private func preview(_ tool: MonitorAssistSelection) -> some View {
        if let picture = model.picture, MonitorStillInspectorPreview.tools.contains(tool) {
            MonitorStillInspectorPreview(picture: picture, tool: tool, renderer: renderer,
                effects: stillInspectorEffects(tool))
        }
    }
    private func stillInspectorEffects(_ tool: MonitorAssistSelection) -> MonitorFrameEffects {
        var value = assist.inspectorImageOptions(tool: tool, transfer: MonitorPhotoAssistTools<Looks>.transfer,
            clipByte: MonitorPhotoAssistTools<Looks>.clipByte)
        value.lutDimension = 0; value.lutRGBA = Data(); value.splitComparison = false
        value.allowsTransferInference = false
        return value
    }
}

/// A still painted with its picture assists, for the picture and effects it was painted from.
struct MonitorStillLook {
    struct Key: Equatable {
        let picture: ObjectIdentifier
        let effects: MonitorFrameEffects
    }
    let key: Key
    let image: UIImage

    /// Paints `picture` off the main thread; nil when nothing is painted.
    static func render(_ picture: UIImage, effects: MonitorFrameEffects,
        renderer: MonitorStillLookRenderer) async -> UIImage? {
        guard let source = picture.cgImage else { return nil }
        let orientation = picture.imageOrientation, scale = picture.scale
        let painted = await Task.detached(priority: .userInitiated) {
            renderer.render(source, effects: effects)
        }.value
        return painted.map { UIImage(cgImage: $0, scale: scale, orientation: orientation) }
    }
}

/// One scope sample of the shown still: the scopes read the picture itself, as they read a frame.
struct MonitorStillScopes {
    let picture: ObjectIdentifier
    let bundle: ScopeAssistBundle

    static func sample(_ picture: UIImage) async -> ScopeAssistBundle {
        let width = CGFloat(ScopeSampler.maxWidth)
        let size = picture.size.width > 0 && picture.size.height > 0
            ? CGSize(width: width, height: max(1, (width * picture.size.height / picture.size.width).rounded()))
            : CGSize(width: 1, height: 1)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        // Drawing applies the still's orientation, so the scopes read it upright.
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            picture.draw(in: CGRect(origin: .zero, size: size))
        }
        let samples = await MonitorUIImageScopeSampler().sample(from: upright, maxWidth: ScopeSampler.maxWidth,
            stride: ScopeSampler.pointStride, includePoints: true,
            transfer: .rec709)
        return ScopeSampler.bundle(samples: samples, transfer: .rec709, clipByte: 255,
            includePoints: true, includeVectorPoints: true, look: nil, previous: .empty)
    }
}

/// The inspected tool on the still, at the inspector's preview size.
struct MonitorStillInspectorPreview: View {
    static let tools: Set<MonitorAssistSelection> = [.peaking, .falseColor, .zebra, .desqueeze, .mirror]
    let picture: UIImage
    let tool: MonitorAssistSelection
    let renderer: MonitorStillLookRenderer
    let effects: MonitorFrameEffects
    @State private var painted: MonitorStillLook?

    private var key: MonitorStillLook.Key {
        var value = effects
        value.desqueezeFactor = 1; value.mirror = false; value.mirrorVertical = false
        return .init(picture: ObjectIdentifier(picture), effects: value)
    }
    var body: some View {
        let rect = DesqueezeAssist.presentationRect(sourceSize: picture.size,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000), effects: effects)
        let shown = painted?.key == key ? painted?.image ?? picture : picture
        Image(uiImage: shown).resizable()
            .aspectRatio(rect.width / max(1, rect.height), contentMode: .fit)
            .scaleEffect(x: effects.mirror ? -1 : 1, y: effects.mirrorVertical ? -1 : 1)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: 160)
            .accessibilityHidden(true)
            .task(id: key) {
                let key = key
                guard MonitorStillLookRenderer.paints(key.effects) else { painted = nil; return }
                let image = await MonitorStillLook.render(picture, effects: key.effects, renderer: renderer)
                guard !Task.isCancelled else { return }
                painted = image.map { .init(key: key, image: $0) }
            }
    }
}
#endif
