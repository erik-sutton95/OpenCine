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
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    private let close: () -> Void
    private let thumbnail: (MonitorMediaRecord<Payload>) -> Thumbnail
    private let picture: (MonitorMediaPlaybackModel<Payload, Look>) -> Picture
    public init(model: MonitorOperatorMediaModel<Payload, Look>, brand: String, close: @escaping () -> Void,
        @ViewBuilder thumbnail: @escaping (MonitorMediaRecord<Payload>) -> Thumbnail,
        @ViewBuilder playbackPicture: @escaping (MonitorMediaPlaybackModel<Payload, Look>) -> Picture) {
        self.model = model; self.brand = brand; self.close = close
        self.thumbnail = thumbnail; self.picture = playbackPicture
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
            MonitorOperatorCatalogScreen(library: library, brand: brand, safeArea: OperatorPanelMetrics.resolvedDeviceSafeArea(
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
                open: { request in _ = model.open(request.record.asset.id, admitted: request.admission) },
                thumbnail: { value in thumbnail(value.record) })
                .overlay {
                    if let player = model.playback {
                        MonitorOperatorBasicPlaybackScreen(model: model, player: player, picture: { picture(player) })
                    }
                }
        }.ignoresSafeArea().preferredColorScheme(.dark)
        .onDisappear { model.closeGallery() }
    }
}

private struct MonitorOperatorBasicPlaybackScreen<Payload: Sendable, Look: Sendable, Picture: View>: View {
    let model: MonitorOperatorMediaModel<Payload, Look>
    let player: MonitorMediaPlaybackModel<Payload, Look>
    let picture: () -> Picture
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MonitorPlaybackScreen(value: presentation, actions: actions, picture: picture,
            feedAssists: { _ in EmptyView() }, canvasAssists: { _, _ in EmptyView() }, tools: { _ in EmptyView() })
            .onAppear { player.setPresentationActive(true); player.setSceneActive(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in player.setSceneActive(phase == .active) }
            .onDisappear { player.setPresentationActive(false) }
    }
    private var presentation: MonitorPlaybackPresentation {
        let asset = player.active?.asset
        let width = player.metadata.width ?? Double(asset?.pixelSize?.width ?? 0)
        let height = player.metadata.height ?? Double(asset?.pixelSize?.height ?? 0)
        let position = player.scrubbing ? player.scrubPosition : player.position
        return MonitorPlaybackPresentation(item: player.token, title: asset?.filename ?? "Media", subtitle: "",
            source: nil, metadata: [], aspect: width > 0 && height > 0 ? width / height : 16 / 9,
            ready: player.ready, error: player.error, progress: asset.flatMap { model.library.progress[$0.id] },
            position: position, duration: player.duration ?? 0,
            positionLabel: time(position), durationLabel: player.duration.map(time) ?? "--:--",
            playing: player.reportedPlaying ?? player.playRequested, reachedEnd: player.reachedEnd,
            scrubbing: player.scrubbing, muted: player.muted, looping: player.looping,
            previous: player.canGoPrevious, next: player.canGoNext, favorite: player.active?.favorite ?? false,
            conform: player.metadata.conform, conformTarget: player.conformTarget, haptics: true, shareEnabled: false)
    }
    private func current(_ token: MonitorPlaybackItemToken) -> Bool { player.token == token && !player.closed }
    private var actions: MonitorPlaybackActions {
        MonitorPlaybackActions(back: model.closePlayback,
            play: { if current($0) { player.setPlaying($1) } }, restart: { if current($0) { player.restart() } },
            seekBy: { if current($0) { player.seek(by: $1) } }, mute: { if current($0) { player.setMuted($1) } },
            loop: { if current($0) { player.setLooping($1) } }, conform: { if current($0) { player.setConformTarget($1) } },
            adjacent: { if current($0) { player.goToAdjacent($1) } },
            favorite: { if current($0), let id = player.active?.asset.id { model.library.toggleFavorite(id) } },
            share: { _ in }, beginScrub: { current($0) ? player.beginScrub() : nil },
            updateScrub: { player.updateScrub(seconds: $1, admitted: $0) },
            updateFrameScrub: { player.updateFrameScrub(delta: $1, width: $2, admitted: $0) },
            commitScrub: { player.commitScrub(admitted: $0) },
            cancelScrub: { player.cancelScrub(interrupted: $1 == .interrupted, admitted: $0) })
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
#endif
