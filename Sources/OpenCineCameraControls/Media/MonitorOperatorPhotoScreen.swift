#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI
import UIKit

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
    @State private var activated = false
    @State private var model: MonitorMediaPictureModel<Payload, UIImage>
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
        deletedReturning: (@MainActor (MonitorMediaLibraryActionToken) -> Void)? = nil) {
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
        .onAppear { model.activate(); activated = true; model.load(loaders, policy: policy); model.readRating(rating) }
        .onDisappear { model.retire() }
        .onChange(of: model.isCurrent) { _, current in if !current && !model.closing { model.sourceChanged() } }
        .onChange(of: model.library.lifetimeToken) { _, _ in model.sourceChanged() }
        .confirmationDialog(model.deletionMessage ?? "Delete this photo from the camera?",
            isPresented: Binding(get: { model.deleteRequestID != nil }, set: { if !$0 { model.cancelDelete(admitted: deleteID) } }),
            titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.confirmDelete(deleteID, operations: operations, completed: finishDeletion) }
                Button("Cancel", role: .cancel) { model.cancelDelete(admitted: deleteID) }
            }
        .overlay { if model.isCurrent, model.optionsPresented { options } }
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
        .alert("Couldn't share this photo", isPresented: Binding(get: { model.failure != nil },
            set: { if !$0 { model.dismissFailure() } })) {
                Button("OK") { model.dismissFailure() }
            } message: { Text(model.failure ?? "") }
    }
    private var photoContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let picture = model.picture { image(picture) }
            else if model.loading {
                VStack(spacing: 12) {
                    ProgressView().tint(MonitorTheme.accent)
                    Text("Preparing image…").font(MonitorTheme.font(14, weight: .medium)).foregroundStyle(MonitorTheme.muted)
                }
            }
            VStack {
                HStack(spacing: 10) {
                    Button { if !model.back() { model.close(completed: close) } } label: { icon(.x) }
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
                    desqueeze
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
        }
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
    private var effects: MonitorFrameEffects {
        var value = MonitorFrameEffects()
        value.desqueezeFactor = assist.isPlaybackVisible(.desqueeze) ? assist.desqueezeFactor : 1
        value.desqueezeHorizontal = assist.desqueezeHorizontal
        return value
    }
    private func image(_ picture: UIImage) -> some View {
        GeometryReader { proxy in
            let rect = DesqueezeAssist.presentationRect(sourceSize: picture.size,
                in: CGRect(origin: .zero, size: proxy.size), effects: effects)
            MonitorInteractivePicture(source: model.presentation, size: rect.size,
                enabled: model.isCurrent && !coverPresented && !model.optionsPresented && model.deleteRequestID == nil) { _ in
                    Image(uiImage: picture).resizable().frame(width: rect.width, height: rect.height)
                }
                .position(x: rect.midX, y: rect.midY)
        }.ignoresSafeArea()
    }
    private var desqueeze: some View {
        MonitorAssistChip(id: MonitorAssistSelection.desqueeze.rawValue,
            isOn: assist.isPlaybackVisible(.desqueeze), compact: true) {
                MonitorAssistToolGlyph(tool: .desqueeze, size: 19)
            }
            .contentShape(Rectangle()).minTapTarget()
            .gesture(LongPressGesture(minimumDuration: 0.25).exclusively(before: TapGesture()).onEnded { value in
                guard model.isCurrent else { return }
                switch value {
                case .first: model.optionsPresented = true
                case .second: assist.togglePlayback(.desqueeze)
                }
            })
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel("Anamorphic Desqueeze").accessibilityValue(assist.isPlaybackVisible(.desqueeze) ? "On" : "Off")
            .accessibilityAction { if model.isCurrent { assist.togglePlayback(.desqueeze) } }
            .accessibilityAction(named: "Options") { if model.isCurrent { model.optionsPresented = true } }
            .accessibilityIdentifier("photo.desqueeze")
    }
    private var options: some View {
        GeometryReader { proxy in
            MonitorInspector(title: MonitorAssistSelection.desqueeze.title, viewport: proxy.size,
                safeArea: OperatorPanelMetrics.resolvedDeviceSafeArea(
                    proxy.safeAreaInsets, window: windowGeometry.safeArea),
                helpVisible: Binding(get: { model.helpPresented }, set: { model.helpPresented = $0 }),
                onClose: { model.optionsPresented = false }) {
                    EmptyView()
                } content: {
                    if let picture = model.picture {
                        Image(uiImage: picture).resizable().aspectRatio(picture.size.width / picture.size.height
                            * (assist.desqueezeHorizontal ? assist.desqueezeFactor : 1 / assist.desqueezeFactor), contentMode: .fit)
                            .frame(maxHeight: 160)
                    }
                    MonitorInspectorCard { DesqueezeLongPressMenu(assist: assist, haptics: haptics) }
                        .environment(\.monitorInspectorHelp, model.helpPresented)
                } footer: { EmptyView() }
                .environment(\.monitorSegmentedAppearance, .inspector)
        }.ignoresSafeArea()
    }
}
#endif
