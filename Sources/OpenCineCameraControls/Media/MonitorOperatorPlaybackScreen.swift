#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia
import SwiftUI

/// Complete operator playback around one existing item owner. Camera facts, native picture,
/// raster preview and the integration's real look catalogue are the only source leaves.
public struct MonitorOperatorPlaybackScreen<Payload: Sendable, Look: Sendable,
    Looks: MonitorLookProvider, Palette: LiveChromePalette,
    Picture: View, Preview: View, LookMenu: View>: View {
    private let model: MonitorOperatorMediaModel<Payload, Look>
    private let initial: MonitorMediaGalleryOpen<Payload>
    private let assist: MonitorAssistState<Looks>?
    private let stores: AssistPanelStores?
    private let looks: FalseColorLooks
    private let haptics: OperatorHaptics
    @Binding private var usage: MonitorToolUsage
    private let cacheOriginal: Bool
    private let deliveryPresented: Bool
    private let operations: MonitorOperatorPlaybackOperations<Payload, Look>
    private let source: (MonitorMediaRecord<Payload>) -> MonitorPlaybackSourceValues
    private let nativeAssists: (MonitorMediaPlaybackModel<Payload, Look>) -> (any MonitorPlaybackAssistService)?
    private let readScopes: (() -> ScopeAssistBundle)?
    private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    private let sourceCurrent: @MainActor () -> Bool
    private let close: () -> Void
    private let share: ((MonitorMediaRecord<Payload>) -> Void)?
    private let picture: (MonitorMediaPlaybackModel<Payload, Look>, MonitorFrameEffects) -> Picture
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    private let onGeometry: (MonitorPlaybackPictureGeometry) -> Void
    private let onShareButtonFrame: (CGRect) -> Void
    private let initialRatingShadeOpen: Bool
    private let signalOptions: MonitorOperatorSignalOptions
    private let availableAssistTools: Set<MonitorAssistSelection>?
    private let initialChromeVisible: Bool
    private let loopAvailable: Bool
    private let interaction: MonitorPlaybackInteractionOptions
    private let paradeIntensityScale: Double
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    @State private var barFrame = CGRect.zero
    @State private var toolbarFrame = CGRect.zero
    @State private var opened = false

    public init(model: MonitorOperatorMediaModel<Payload, Look>, initial: MonitorMediaGalleryOpen<Payload>,
        assist: MonitorAssistState<Looks>?, stores: AssistPanelStores?, looks: FalseColorLooks,
        palette: Palette.Type, haptics: OperatorHaptics, usage: Binding<MonitorToolUsage>,
        cacheOriginal: Bool, deliveryPresented: Bool,
        operations: MonitorOperatorPlaybackOperations<Payload, Look>,
        source: @escaping (MonitorMediaRecord<Payload>) -> MonitorPlaybackSourceValues,
        nativeAssists: @escaping (MonitorMediaPlaybackModel<Payload, Look>) -> (any MonitorPlaybackAssistService)?,
        readScopes: (() -> ScopeAssistBundle)? = nil,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        sourceCurrent: @escaping @MainActor () -> Bool = { true },
        close: @escaping () -> Void, share: ((MonitorMediaRecord<Payload>) -> Void)? = nil,
        onGeometry: @escaping (MonitorPlaybackPictureGeometry) -> Void = { _ in },
        onShareButtonFrame: @escaping (CGRect) -> Void = { _ in }, initialRatingShadeOpen: Bool = false,
        signalOptions: MonitorOperatorSignalOptions = .init(), availableAssistTools: Set<MonitorAssistSelection>? = nil,
        initialChromeVisible: Bool = true, loopAvailable: Bool = true,
        interaction: MonitorPlaybackInteractionOptions = .init(), paradeIntensityScale: Double = 1,
        @ViewBuilder picture: @escaping (MonitorMediaPlaybackModel<Payload, Look>, MonitorFrameEffects) -> Picture,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.model = model; self.initial = initial; self.assist = assist; self.stores = stores
        self.looks = looks; self.haptics = haptics; _usage = usage
        self.cacheOriginal = cacheOriginal; self.deliveryPresented = deliveryPresented
        self.operations = operations; self.source = source; self.nativeAssists = nativeAssists
        self.readScopes = readScopes; self.configureDisplay = configureDisplay
        self.sourceCurrent = sourceCurrent; self.close = close; self.share = share; self.onGeometry = onGeometry
        self.onShareButtonFrame = onShareButtonFrame; self.initialRatingShadeOpen = initialRatingShadeOpen
        self.signalOptions = signalOptions; self.availableAssistTools = availableAssistTools
        self.initialChromeVisible = initialChromeVisible; self.loopAvailable = loopAvailable
        self.interaction = interaction; self.paradeIntensityScale = paradeIntensityScale
        self.picture = picture; self.preview = preview; self.lookMenu = lookMenu
    }

    private var player: MonitorMediaPlaybackModel<Payload, Look>? { model.playback }
    private var effects: MonitorFrameEffects { assist?.playbackEffects ?? .init() }
    private var sourceValues: MonitorPlaybackSourceValues {
        player?.active.map(source) ?? source(initial.record)
    }
    public var body: some View {
        playbackLifecycle
        .onChange(of: player?.ready) { _, _ in synchronize() }
        .onChange(of: player?.lookResolution) { _, _ in synchronize() }
        .onChange(of: effects) { _, _ in synchronize() }
        .onChange(of: assist?.playbackVisibleTools) { _, _ in synchronize() }
        .onChange(of: sourceValues.availability) { _, availability in
            if availability == .original { player?.refreshTransfer() }
        }
        .onChange(of: player?.muted) { _, _ in synchronize() }
        .onChange(of: player?.conformTarget) { _, _ in synchronize() }
    }

    private var playbackLifecycle: some View {
        playbackContent
        .statusBarHidden().preferredColorScheme(.dark)
        .onAppear {
            assist?.gradesClip = true
            if !opened { model.ratingShadeOpen = initialRatingShadeOpen }
            model.setPlayerVisible(true); model.setSceneActive(scenePhase == .active)
            opened = sourceCurrent() && model.open(initial.record, playlist: initial.playlist, admitted: initial.admission)
            model.setDeliveryPresented(deliveryPresented)
            if let player { nativeAssists(player)?.activate() }
            synchronize()
        }
        .onDisappear {
            let previous = player.flatMap(nativeAssists)
            model.closePlayback()
            previous?.close()
            assist?.configureTool = nil; assist?.gradesClip = false
        }
        .onChange(of: scenePhase) { _, phase in model.setSceneActive(phase == .active) }
        .onChange(of: deliveryPresented) { _, value in model.setDeliveryPresented(value) }
        .onChange(of: player?.token) { _, _ in synchronize() }
        .onChange(of: sourceCurrent()) { _, current in
            if !current { retirePlayer() }
        }
        .onChange(of: player == nil) { _, missing in
            if missing, opened, model.playback == nil, sourceCurrent() { close() }
        }
    }

    private var playbackContent: some View {
        Group {
            if sourceCurrent(), let player, model.isCurrent(player.token) {
                playbackCanvas(player)
            } else { MonitorOperatorMediaUnavailable(close: back) }
        }
    }

    private func retirePlayer() {
        let previous = player.flatMap(nativeAssists)
        model.closePlayback()
        previous?.close()
    }

    private func playbackCanvas(_ player: MonitorMediaPlaybackModel<Payload, Look>) -> some View {
        let access = accessOnce()
        return MonitorPlaybackScreen(value: presentation(player, access: access), actions: actions(player, access: access),
            coverPresented: deliveryPresented, onGeometry: onGeometry,
            onBarFrame: { barFrame = $0 },
            slots: .init(headerAccessory: { AnyView(ratingDetails(player)) },
                onShareButtonFrame: onShareButtonFrame,
                headerActionAccessory: { AnyView(ratingAnchor(player)) }),
            picture: { picture(player, effects) },
            feedAssists: { rect in feedMarks(rect) },
            canvasAssists: { size, rect in canvasAssists(size, rect, player: player) },
            tools: { context in palette(context) })
            .overlay { playbackInspector(player) }
    }

    @ViewBuilder private func ratingAnchor(_ player: MonitorMediaPlaybackModel<Payload, Look>) -> some View {
        if operations.rating != nil {
            MonitorPlaybackRatingAnchor(stars: model.ratingStars,
                expanded: Binding(get: { model.ratingShadeOpen }, set: { model.ratingShadeOpen = $0 }))
        }
    }
    @ViewBuilder private func ratingDetails(_ player: MonitorMediaPlaybackModel<Payload, Look>) -> some View {
        if let rating = operations.rating {
            MonitorPlaybackRatingDetails(stars: model.ratingStars, levels: rating.levels,
                enabled: model.isCurrent(player.token), notice: model.ratingNotice,
                expanded: model.ratingShadeOpen,
                select: { model.setRating($0, service: rating) })
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private func playbackInspector(_ player: MonitorMediaPlaybackModel<Payload, Look>) -> some View {
        if let assist, let tool = assist.configureTool, case let tools = availableTools, tools.contains(tool), hasOptions(tool) {
            GeometryReader { proxy in
                let values = sourceValues
                MonitorOperatorAssistInspector(tool: tool, assist: assist, stores: stores,
                        looks: looks, palette: Palette.self, haptics: haptics,
                        sourceTransfer: values.resolvedTransfer(fallback: player.transfer ?? effects.transfer),
                        clipByte: values.clipByte ?? effects.resolvedClipByte, viewport: proxy.size,
                        safeArea: OperatorPanelMetrics.resolvedDeviceSafeArea(
                            proxy.safeAreaInsets, window: windowGeometry.safeArea),
                        available: Set(tools.filter(hasOptions)),
                        signalOptions: signalOptions,
                        onDismiss: { assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
                        .environment(\.audioInspectorLevels, nativeAssists(player)?.audioLevels)
            }.ignoresSafeArea().zIndex(6)
        }
    }

    private func synchronize() {
        model.synchronizePlayback(cacheOriginal: cacheOriginal, operations: operations)
        guard let player, model.isCurrent(player.token) else { return }
        let token = player.token
        nativeAssists(player)?.synchronize(item: token, effects: effects,
            audioVisible: assist?.isPlaybackVisible(.audioMeters) == true, outputMuted: player.muted || player.conformTarget != nil,
            ifCurrent: { model.isCurrent(token) })
    }
    private func back() { model.setPlayerVisible(false); close() }
    private func current(_ token: MonitorPlaybackItemToken, _ action: (MonitorMediaPlaybackModel<Payload, Look>) -> Void) {
        guard model.isCurrent(token), let player else { return }; action(player)
    }
    /// The host's access answer for a record, asked once per body pass. A host can read the file
    /// system to answer (whether the cached original is on disk), and one pass needs it for
    /// share and twice for delete; the page re-renders on every position tick.
    private func accessOnce() -> (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess? {
        guard let access = operations.access else { return { _ in nil } }
        var cached: (id: MediaAssetID, value: MonitorMediaGalleryAccess)?
        return { record in
            if let cached, cached.id == record.asset.id { return cached.value }
            let value = access(record)
            cached = (record.asset.id, value)
            return value
        }
    }

    private func actions(_ owner: MonitorMediaPlaybackModel<Payload, Look>,
        access: (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess?) -> MonitorPlaybackActions {
        var result = MonitorPlaybackActions(back: back,
            play: { token, value in current(token) { $0.setPlaying(value) } },
            restart: { current($0) { $0.restart() } }, seekBy: { token, delta in current(token) { $0.seek(by: delta) } },
            mute: { token, value in current(token) { $0.setMuted(value) } },
            loop: { token, value in current(token) { $0.setLooping(value) } },
            conform: { token, value in current(token) { $0.setConformTarget(value) } },
            adjacent: { token, offset in if !model.adjacent(offset, admitted: token) { haptics.confirm() } },
            favorite: { token in current(token) { if let record = $0.active {
                if let favorite = operations.favorite { favorite(record) }
                else { model.library.toggleFavorite(record.asset.id) }
            } } },
            share: { token in current(token) { owner in
                guard let record = owner.active, let share else { return }
                if let access = operations.access {
                    guard access(record).share == true, model.isCurrent(token) else { return }
                }
                guard model.beginShare(token) else { return }
                share(record)
            } },
            delete: mayDelete(owner.active, access: access) ? operations.delete.map { _ in {
                model.deleteCurrent(admitted: $0, operations: operations) } } : nil,
            beginScrub: { model.isCurrent($0) ? owner.beginScrub() : nil },
            updateScrub: { owner.updateScrub(seconds: $1, admitted: $0) },
            updateFrameScrub: { owner.updateFrameScrub(delta: $1, width: $2, admitted: $0) },
            commitScrub: { owner.commitScrub(admitted: $0) },
            cancelScrub: { owner.cancelScrub(interrupted: $1 == .interrupted, admitted: $0) })
        if operations.captureDeletion != nil, mayDelete(owner.active, access: access) {
            result.deletionConfirmation = .init(
                capture: { model.captureDeletion(admitted: $0, operations: operations) },
                isCurrent: { model.isDeletionCurrent(admitted: $0) },
                confirm: { model.confirmDeletion(admitted: $0) },
                cancel: { model.cancelDeletion(admitted: $0) })
        }
        return result
    }

    private func mayDelete(_ record: MonitorMediaRecord<Payload>?,
        access: (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess?) -> Bool {
        guard let record else { return false }
        if let answer = access(record) { return answer.delete == true }
        return record.asset.deletable == true
    }

    private func mayShare(_ record: MonitorMediaRecord<Payload>,
        access: (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess?) -> Bool {
        guard share != nil else { return false }
        if let answer = access(record) { return answer.share == true }
        return true
    }

    private func presentation(_ player: MonitorMediaPlaybackModel<Payload, Look>,
        access: (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess?) -> MonitorPlaybackPresentation {
        let record = player.active ?? initial.record, asset = record.asset, values = sourceValues
        let listed = PlaybackVideoLayout.size(fromResolution: record.facts.resolution)
        let width: Double = player.metadata.width ?? asset.pixelSize.map { Double($0.width) }
            ?? listed.map { Double($0.width) } ?? 16
        let height: Double = player.metadata.height ?? asset.pixelSize.map { Double($0.height) }
            ?? listed.map { Double($0.height) } ?? 9
        let size = CGSize(width: width, height: height)
        let rect = DesqueezeAssist.presentationRect(sourceSize: size,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000), effects: effects)
        let duration = player.duration ?? asset.durationSeconds ?? 0
        let buffered: Double
        if let through = values.bufferedThroughSeconds {
            if player.ready, through.isFinite, through >= 0,
                let nativeDuration = player.metadata.duration,
                nativeDuration.isFinite, nativeDuration > 0
            { buffered = min(through, nativeDuration) }
            else { buffered = 0 }
        } else { buffered = values.buffered ?? 0 }
        let position = player.scrubbing ? player.scrubPosition : player.position
        let bytes = asset.representations.first { $0.role == .original }?.byteCount
        let byteLabel = bytes.map(MediaClipFormatting.byteLabel)
        let color = values.colorLabel ?? asset.colorLabel
        let frameRate = asset.frameRate.map { String(format: "%g", $0) }
        let subtitle = values.headerSubtitle(facts: [record.facts.resolution, frameRate.map { $0 + "p" }, color, byteLabel]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        var metadata = [MonitorMetadataRow("File", asset.filename)]
        if let date = asset.capturedAt { metadata.append(.init("Captured", date.formatted(date: .abbreviated, time: .standard))) }
        if let resolution = record.facts.resolution { metadata.append(.init("Format", resolution)) }
        if let frameRate { metadata.append(.init("Frame rate", frameRate + " fps")) }
        if let color { metadata.append(.init("Colour", color)) }
        metadata.append(.init("Duration", time(duration, player: player, values: values)))
        if let byteLabel { metadata.append(.init("Size", byteLabel)) }
        if let label = values.sourceLabel { metadata.append(.init("Availability", label)) }
        metadata.append(contentsOf: values.metadata.map { .init($0.title, $0.value) })
        return .init(item: player.token, title: asset.filename, subtitle: subtitle, source: values.sourceLabel,
            metadata: metadata, aspect: Double(rect.width / max(1, rect.height)),
            mirrorHorizontal: effects.mirror, mirrorVertical: effects.mirrorVertical,
            ready: player.ready, error: player.error ?? (player.closed ? "This clip is not cached on the phone." : nil), progress: values.progress,
            position: position, duration: duration, buffered: buffered,
            positionLabel: time(position, player: player, values: values),
            durationLabel: time(duration, player: player, values: values),
            playing: player.canPause && !player.scrubbing,
            reachedEnd: player.reachedEnd, scrubbing: player.scrubbing, muted: player.muted,
            looping: player.looping, previous: player.canGoPrevious, next: player.canGoNext,
            favorite: model.library.record(asset.id)?.favorite ?? record.favorite, conform: player.metadata.conform,
            conformTarget: player.conformTarget, haptics: haptics.isEnabled(),
            initialChromeVisible: initialChromeVisible, loopAvailable: loopAvailable, shareEnabled: mayShare(record, access: access),
            doubleTapResetsZoom: interaction.doubleTapResetsZoom, continuousPanBounds: interaction.continuousPanBounds,
            zoomBoundary: interaction.zoomAgainstCanvas ? .canvas : .picture,
            horizontalPresentationScale: interaction.horizontalPresentationScale,
            verticalPresentationScale: interaction.verticalPresentationScale)
    }
    private func time(_ seconds: Double, player: MonitorMediaPlaybackModel<Payload, Look>,
        values: MonitorPlaybackSourceValues) -> String {
        let speed = player.conformTarget.flatMap { target in player.metadata.conform.captureRate.map {
            MonitorConformPreview.speed(captureRate: $0, targetRate: target) } } ?? 1
        let value = MonitorConformPreview.conformedDuration(sourceSeconds: seconds, speed: speed)
        if let label = values.clockStyle.timeLabel(seconds: value) { return label }
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "0:00" }
        return MediaClipFormatting.durationLabel(seconds: Int(value.rounded(.down)))
    }
    private func feedMarks(_ rect: CGRect) -> some View {
        ZStack {
            if let assist {
                if assist.isPlaybackVisible(.guides) { GuidesAssist.overlay(feed: rect, assist: assist, fallback: assist.guideAspect) }
                if assist.isPlaybackVisible(.grid) { MonitorFeedGrid(feed: rect, thirds: assist.gridThirds, phi: assist.gridPhi, diagonal: assist.gridDiagonal) }
                if assist.isPlaybackVisible(.crosshair) { MonitorFeedCrosshair(feed: rect) }
                if assist.splitComparison, assist.isPlaybackVisible(.lut) { MonitorFeedComparisonMarks(vertical: assist.splitVertical, feed: rect) }
            }
        }.allowsHitTesting(false)
    }
    private func options(_ tool: MonitorAssistSelection) {
        guard let assist, availableTools.contains(tool), hasOptions(tool) else { return }
        assist.longPressAnchorRect = .init(x: toolbarFrame.minX, y: toolbarFrame.minY,
            width: toolbarFrame.width, height: toolbarFrame.height)
        assist.configureTool = tool
        if tool == .lut { assist.showLUTPicker = false }
    }
    @ViewBuilder private func canvasAssists(_ size: CGSize, _ rect: CGRect,
        player: MonitorMediaPlaybackModel<Payload, Look>) -> some View {
        if let assist, let stores {
            let canvas = CGRect(origin: .zero, size: size)
            let values = sourceValues, tools = availableTools(values)
            let clearance = EdgeInsets(top: 56, leading: 56, bottom: 110, trailing: 56)
            if let readScopes {
                MonitorScopeOverlays(assist: assist, stores: stores, haptics: haptics, canvas: canvas,
                    feed: rect, chromeClearance: clearance, readBundle: readScopes,
                    configureDisplay: configureDisplay, playback: true, available: Set(tools), paradeIntensityScale: paradeIntensityScale)
            }
            if assist.isPlaybackVisible(.audioMeters), let levels = nativeAssists(player)?.audioLevels {
                AudioMeterOverlay(stores: stores, levels: levels, sensitivity: nil, bounds: canvas,
                    chromeClearance: clearance, hapticsEnabled: haptics.isEnabled(), onConfigure: { options(.audioMeters) })
            }
            if assist.isPlaybackVisible(.falseColor), tools.contains(.falseColor), assist.falseColorReference, signalOptions.referenceAvailable != false,
                let transfer = values.resolvedTransfer(fallback: player.transfer ?? effects.transfer) {
                FalseColorReferenceOverlay(stores: stores, looks: looks, scale: assist.falseColorScale,
                    transfer: transfer,
                    rec709: assist.falseColorRec709, clipByte: values.clipByte ?? effects.resolvedClipByte, bounds: canvas,
                    chromeClearance: clearance, hapticsEnabled: haptics.isEnabled(), onConfigure: { options(.falseColor) },
                    referenceValues: signalOptions.reference)
            }
        }
    }
    /// One source-values read per call: the host's values can be costly (they may check its
    /// cache on disk), and reading them per tool made one body pass call them dozens of times.
    private var availableTools: [MonitorAssistSelection] { availableTools(sourceValues) }
    private func availableTools(_ values: MonitorPlaybackSourceValues) -> [MonitorAssistSelection] {
        guard assist != nil else { return [] }
        let scopes: Set<MonitorAssistSelection> = [.waveform, .parade, .histogram, .vectorscope, .trafficLights, .ndMeter]
        return MonitorAssistSelection.playbackToolbarCases.filter {
            (availableAssistTools?.contains($0) ?? true)
                && (values.allowsSignalFallback || values.transfer != nil || ![MonitorAssistSelection.falseColor, .zebra, .trafficLights, .ndMeter].contains($0)) && ($0 != .audioMeters || (stores != nil && player.flatMap(nativeAssists) != nil))
                && ((stores != nil && readScopes != nil) || !scopes.contains($0))
        }
    }
    private func hasOptions(_ tool: MonitorAssistSelection) -> Bool {
        let stored: Set<MonitorAssistSelection> = [.zebra, .waveform, .parade, .histogram,
            .vectorscope, .trafficLights, .ndMeter, .audioMeters]
        return tool.hasConfiguration && (stores != nil || !stored.contains(tool)
            || (tool == .zebra && signalOptions.zebra != nil))
    }
    @ViewBuilder private func palette(_ context: MonitorPlaybackToolsContext) -> some View {
        if let assist {
            let tools = availableTools
            let (metrics, frame) = MonitorAssistPaletteLayout.fieldMonitor(context.presentation,
                toolCount: tools.count, safeTop: context.safeTop)
            MonitorAssistPalette(tools: tools.map { .init(id: $0.rawValue, title: $0.rawValue,
                    enabled: assist.isPlaybackVisible($0), hasOptions: hasOptions($0), accessibilityLabel: $0.title) },
                layout: metrics, usageSeed: MonitorToolUsage.fieldMonitorSeed, usage: $usage,
                expanded: context.expanded, onToggle: { if let tool = MonitorAssistSelection(rawValue: $0) { assist.togglePlayback(tool) } },
                onOptions: { if let tool = MonitorAssistSelection(rawValue: $0) { options(tool) } }) { id in
                    if let tool = MonitorAssistSelection(rawValue: id), let glyph = tool.sharedTool { MonitorAssistToolGlyph(tool: glyph, size: nil) }
                }
                .background { GeometryReader { proxy in
                    Color.clear.onAppear { toolbarFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in toolbarFrame = frame }
                } }
                .position(x: frame.midX, y: frame.midY)
                .frame(width: context.presentation.viewport.width, height: context.presentation.viewport.height, alignment: .topLeading)
                .onAppear { toolbarFrame = frame.cgRect }
        }
    }
}
/// Shared return surface for a refused or retired media source. Close remains independent
/// of source admission, so an unavailable item cannot trap the operator in its cover.
public struct MonitorOperatorMediaUnavailable: View {
    private let closeEnabled: Bool
    private let close: @MainActor () -> Void
    public init(closeEnabled: Bool = true, close: @escaping @MainActor () -> Void) {
        self.closeEnabled = closeEnabled; self.close = close
    }
    public var body: some View {
        VStack(spacing: 16) {
            Text("Media unavailable").font(MonitorTheme.font(20, weight: .semibold))
                .foregroundStyle(MonitorTheme.text).accessibilityIdentifier("monitor.media.unavailable")
            Text("This media is no longer available.").font(MonitorTheme.font(14, weight: .medium))
                .foregroundStyle(MonitorTheme.muted).multilineTextAlignment(.center)
            Button("Close", action: close).font(MonitorTheme.font(14, weight: .semibold))
                .foregroundStyle(MonitorTheme.text).padding(.horizontal, 24).padding(.vertical, 14)
                .background(MonitorTheme.surface, in: Capsule()).buttonStyle(.monitorTapTarget)
                .disabled(!closeEnabled).accessibilityIdentifier("monitor.media.unavailable.close")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).ignoresSafeArea().statusBarHidden().preferredColorScheme(.dark)
    }
}
#endif
