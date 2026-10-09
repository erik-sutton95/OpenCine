#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Shared catalog and nested player. Native builders receive admitted owners, never URLs or policy.
public struct MonitorOperatorMediaScreen<Payload: Sendable, Look: Sendable, Thumbnail: View, Picture: View>: View {
    private let model: MonitorOperatorMediaModel<Payload, Look>
    private let brand: String
    private let coverSafeArea: EdgeInsets?
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    private let close: () -> Void
    private let thumbnail: (MonitorMediaRecord<Payload>) -> Thumbnail
    private let playback: @MainActor (MonitorMediaGalleryOpen<Payload>,
        Binding<MonitorMediaGalleryOpen<Payload>?>, Binding<MonitorToolUsage>) -> AnyView
    @State private var playbackRequest: MonitorMediaGalleryOpen<Payload>?
    @State private var usage = MonitorToolUsage()

    public init(model: MonitorOperatorMediaModel<Payload, Look>, brand: String, close: @escaping () -> Void,
        safeArea: EdgeInsets? = nil,
        @ViewBuilder thumbnail: @escaping (MonitorMediaRecord<Payload>) -> Thumbnail,
        @ViewBuilder playbackPicture: @escaping (MonitorMediaPlaybackModel<Payload, Look>) -> Picture) {
        let absentAssist: MonitorAssistState<MonitorLUTLooks>? = nil
        self.init(model: model, brand: brand, close: close, safeArea: safeArea,
            playbackAssist: absentAssist, preferences: nil,
            assistPanels: nil, falseColorLooks: .signal,
            availableAssistTools: [], assistPreview: nil, lookMenu: nil,
            thumbnail: thumbnail, playbackPicture: playbackPicture)
    }

    public init<Looks: MonitorLookProvider>(model: MonitorOperatorMediaModel<Payload, Look>,
        brand: String, close: @escaping () -> Void, safeArea: EdgeInsets? = nil,
        assist: MonitorAssistState<Looks>, preferences: MonitorOperatorPreferences,
        assistPanels: AssistPanelStores? = nil, falseColorLooks: FalseColorLooks = .signal,
        availableAssistTools: Set<MonitorAssistSelection>,
        assistPreview: ((MonitorMediaPlaybackModel<Payload, Look>, MonitorAssistSelection) -> AnyView)? = nil, lookMenu: (() -> AnyView)? = nil,
        @ViewBuilder thumbnail: @escaping (MonitorMediaRecord<Payload>) -> Thumbnail,
        @ViewBuilder playbackPicture: @escaping (MonitorMediaPlaybackModel<Payload, Look>) -> Picture) {
        self.init(model: model, brand: brand, close: close, safeArea: safeArea,
            playbackAssist: assist, preferences: preferences, assistPanels: assistPanels,
            falseColorLooks: falseColorLooks,
            availableAssistTools: availableAssistTools, assistPreview: assistPreview, lookMenu: lookMenu,
            thumbnail: thumbnail, playbackPicture: playbackPicture)
    }

    private init<Looks: MonitorLookProvider>(model: MonitorOperatorMediaModel<Payload, Look>,
        brand: String, close: @escaping () -> Void, safeArea: EdgeInsets?,
        playbackAssist: MonitorAssistState<Looks>?, preferences: MonitorOperatorPreferences?,
        assistPanels: AssistPanelStores?, falseColorLooks: FalseColorLooks,
        availableAssistTools: Set<MonitorAssistSelection>,
        assistPreview: ((MonitorMediaPlaybackModel<Payload, Look>, MonitorAssistSelection) -> AnyView)?, lookMenu: (() -> AnyView)?,
        thumbnail: @escaping (MonitorMediaRecord<Payload>) -> Thumbnail,
        playbackPicture: @escaping (MonitorMediaPlaybackModel<Payload, Look>) -> Picture) {
        self.model = model; self.brand = brand; self.close = close; self.coverSafeArea = safeArea
        self.thumbnail = thumbnail
        playback = { request, presented, usage in
            let cache: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
            if model.library.canTransfer {
                cache = { record in _ = try? await model.library.cacheOriginal(record.asset.id) }
            } else {
                cache = nil
            }
            return AnyView(MonitorOperatorPlaybackScreen(model: model, initial: request,
                assist: playbackAssist, stores: assistPanels, looks: falseColorLooks,
                palette: MonitorDefaultLivePalette.self,
                haptics: OperatorHaptics(isEnabled: { preferences?.haptics ?? true }), usage: usage,
                cacheOriginal: preferences?.cacheOriginals == true, deliveryPresented: false,
                operations: .init(cacheOriginal: cache),
                source: { record in .init(progress: model.library.progress[record.asset.id], colorLabel: record.asset.colorLabel) },
                nativeAssists: { _ in nil },
                close: { presented.wrappedValue = nil }, availableAssistTools: availableAssistTools,
                picture: { owner, _ in playbackPicture(owner) },
                preview: { tool in
                    guard let owner = model.playback else { return AnyView(EmptyView()) }
                    let token = owner.token
                    guard model.isCurrent(token), model.playback === owner, owner.token == token else { return AnyView(EmptyView()) }
                    let rendered = assistPreview?(owner, tool) ?? AnyView(EmptyView())
                    guard model.isCurrent(token), model.playback === owner, owner.token == token else { return AnyView(EmptyView()) }
                    return rendered
                },
                lookMenu: { lookMenu?() ?? AnyView(EmptyView()) }))
        }
    }

    private var library: MonitorMediaLibraryModel<Payload> { model.library }
    private var operations: MonitorMediaGalleryOperations<Payload> {
        let download: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
        if library.canTransfer {
            download = { record in _ = try? await library.cacheOriginal(record.asset.id) }
        } else {
            download = nil
        }
        let delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
        if library.canDelete {
            delete = { record in _ = try? await library.delete([record.asset.id]) }
        } else {
            delete = nil
        }
        return .init(download: download, delete: delete)
    }
    private var colorChoices: [MonitorMediaFilterChoice] {
        let values = library.records.compactMap { record -> MonitorMediaFilterChoice? in
            guard let id = record.facts.color, let label = record.asset.colorLabel else { return nil }
            return .init(id: id, label: label)
        }
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.label < $1.label }
    }
    public var body: some View {
        GeometryReader { proxy in
            MonitorOperatorCatalogScreen(library: library, brand: brand, safeArea: coverSafeArea ?? OperatorPanelMetrics.resolvedDeviceSafeArea(
                        proxy.safeAreaInsets, window: windowGeometry.safeArea),
                sourceAvailable: library.canRefresh, operations: operations, colorChoices: colorChoices,
                facts: { record in
                    let seconds = record.asset.durationSeconds.flatMap { value -> Int? in
                        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
                        return Int(value)
                    }
                    return .init(resolution: record.facts.resolution,
                        byteCount: record.asset.representations.first { $0.role == .original }?.byteCount,
                        durationSeconds: seconds, dateKey: record.facts.dateKey, colorLabel: record.asset.colorLabel)
                }, begin: model.showGallery, close: { model.closeGallery(); close() },
                open: { request in
                    guard model.galleryOpen, library.isCurrent(request.admission) else { return }
                    playbackRequest = request
                },
                thumbnail: { value in thumbnail(value.record) })
                .overlay {
                    if let request = playbackRequest {
                        playback(request, $playbackRequest, $usage).id(request.id)
                    }
                }
        }.ignoresSafeArea().preferredColorScheme(.dark)
        .onDisappear { model.closeGallery() }
    }
}

#endif
