#if os(iOS)
    import MonitorPresentation
    import OpenCineMedia
    import SwiftUI
    import UIKit

    private enum PlaybackFrameScrubMetrics { static let longPressDuration = 0.35 }
    private enum PlaybackFlashMetrics {
        static let fadeIn = 0.12
        static let hold = 0.55
        static let fadeOut = 0.22
    }

    /// The common player canvas and operator chrome. The native picture is one fixed child;
    /// inspectors, transport, rotation and clean view never replace that child.
    public struct MonitorPlaybackScreen<
        Picture: View, FeedAssists: View, CanvasAssists: View, Tools: View
    >: View {
        private let value: MonitorPlaybackPresentation
        private let actions: MonitorPlaybackActions
        private let picture: () -> Picture
        private let feedAssists: (CGRect) -> FeedAssists
        private let canvasAssists: (CGSize, CGRect) -> CanvasAssists
        private let tools: (MonitorPlaybackToolsContext) -> Tools
        private let onGeometry: (MonitorPlaybackPictureGeometry) -> Void
        private let onBarFrame: (CGRect) -> Void
        private let coverPresented: Bool
        private let slots: MonitorPlaybackPageSlots
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @Environment(\.scenePhase) private var scenePhase
        @State private var editing = MonitorPlaybackEditing()
        @State private var chromeVisible = true
        @State private var assistMode = false
        @State private var isInfoPresented = false
        @State private var isConformPresented = false
        @State private var isDeleteConfirmPresented = false
        @State private var deleteItem: MonitorPlaybackItemToken?
        @State private var capturedDeletion: MonitorPlaybackDeletionConfirmation?
        @State private var capturedDeletionActions: MonitorPlaybackDeletionActions?
        @State private var zoom = MonitorPlaybackZoom()
        @State private var zoomContainerSize: CGSize = .zero
        @State private var zoomPictureSize: CGSize = .zero
        @State private var suppressNextPlaybackTap = false
        @State private var isFrameScrubbing = false
        @State private var frameScrubVideoWidth: CGFloat = 0
        @State private var frameScrubPending = false
        @State private var frameEditing = MonitorEditingSession()
        @State private var pinchItem: MonitorPlaybackItemToken?
        @State private var panItem: MonitorPlaybackItemToken?
        @State private var playbackFlashIcon: MonitorIcon?
        @State private var playbackFlashVisible = false
        @State private var playbackFlashTask: Task<Void, Never>?
        @GestureState private var framePointerActive = false
        public init(
            value: MonitorPlaybackPresentation, actions: MonitorPlaybackActions,
            coverPresented: Bool = false,
            onGeometry: @escaping (MonitorPlaybackPictureGeometry) -> Void = { _ in },
            onBarFrame: @escaping (CGRect) -> Void = { _ in },
            slots: MonitorPlaybackPageSlots = .init(),
            @ViewBuilder picture: @escaping () -> Picture,
            @ViewBuilder feedAssists: @escaping (CGRect) -> FeedAssists,
            @ViewBuilder canvasAssists: @escaping (CGSize, CGRect) -> CanvasAssists,
            @ViewBuilder tools: @escaping (MonitorPlaybackToolsContext) -> Tools
        ) {
            self.value = value
            self.actions = actions
            self.coverPresented = coverPresented
            self.onGeometry = onGeometry
            self.onBarFrame = onBarFrame
            self.picture = picture
            self.slots = slots
            _chromeVisible = State(initialValue: value.initialChromeVisible)
            self.feedAssists = feedAssists
            self.canvasAssists = canvasAssists
            self.tools = tools
        }
        private var isPlaying: Bool { value.playing }
        private var isMuted: Bool { value.muted }
        private var currentTime: Double { value.position }
        private var duration: Double { value.duration }
        private var scrubTime: Double { value.position }
        private var isClipReady: Bool { value.ready }
        private var loadError: String? { value.error }
        private var reachedEnd: Bool { value.reachedEnd }
        private var isLooping: Bool { value.looping }
        private var conformSource: MonitorConformPreview.Source { value.conform }
        private var conformTarget: Double? { value.conformTarget }
        private var canGoPrevious: Bool { value.previous }
        private var canGoNext: Bool { value.next }

        public var body: some View {
            playerContent
                // A full-screen cover hides the root, so the player publishes the review safe area.
                .monitorReviewSafeArea()
                .onChange(of: value.item) { _, _ in
                    cancelDeleteConfirmation()
                    cancelEditing(.contextChanged)
                    zoom.reset()
                    assistMode = false
                    isFrameScrubbing = false
                    frameScrubPending = false
                    playbackFlashTask?.cancel()
                    playbackFlashIcon = nil
                }
                .onChange(of: isConformPresented) { _, shown in if shown { assistMode = false } }
                .onChange(of: isInfoPresented) { _, shown in if shown { assistMode = false } }
                .onChange(of: coverPresented) { _, shown in if shown { assistMode = false } }
                .onChange(of: chromeVisible) { _, shown in
                    if !shown { assistMode = false }
                    slots.onChromeVisibilityChanged(shown)
                }
                .onChange(of: assistMode) { _, shown in slots.onAssistExpansionChanged(shown) }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { cancelEditing(.contextChanged) }
                }
                .onChange(of: framePointerActive) { _, active in
                    if !active, frameEditing.end() { cancelEditing(.interrupted) }
                }
                .onDisappear {
                    cancelDeleteConfirmation()
                    playbackFlashTask?.cancel()
                    cancelEditing(.disappeared)
                }
        }

        private var playerContent: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { geo in
                    let container = CGRect(origin: .zero, size: geo.size)
                    let videoRect = Self.fit(aspect: value.aspect, in: container)

                    ZStack {
                        picture()
                            .scaleEffect(
                                x: value.mirrorHorizontal ? -1 : 1,
                                y: value.mirrorVertical ? -1 : 1,
                                anchor: .center
                            )
                            .scaleEffect(zoom.scale)
                            .offset(zoom.offset)
                    }
                    .frame(width: videoRect.width, height: videoRect.height)
                    .clipped()
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .allowsHitTesting(false)

                    feedAssists(videoRect)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: videoRect.width, height: videoRect.height)
                        .contentShape(Rectangle())
                        .onAppear {
                            updateGeometry(canvas: geo.size, feed: videoRect)
                        }
                        .onChange(of: videoRect.size) { _, size in
                            cancelEditing(.interrupted)
                            zoom.endGesture(
                                size: value.zoomBoundary == .canvas ? geo.size : size,
                                horizontalPresentationScale: value.horizontalPresentationScale,
                                verticalPresentationScale: value.verticalPresentationScale)
                            updateGeometry(canvas: geo.size, feed: videoRect)
                        }
                        .onChange(of: zoom) { _, _ in
                            updateGeometry(canvas: geo.size, feed: videoRect)
                        }
                        .onChange(of: value.item) { _, _ in
                            updateGeometry(canvas: geo.size, feed: videoRect)
                        }
                        .gesture(playbackVideoGesture)
                        .simultaneousGesture(playbackFrameTapGesture)
                        .simultaneousGesture(playbackFrameScrubGesture)
                        .position(x: videoRect.midX, y: videoRect.midY)

                    playbackTransportFlashOverlay(in: videoRect)
                    playbackFrameScrubOverlay(in: videoRect)

                    if canGoPrevious || canGoNext {
                        clipNavigationArrows(in: videoRect)
                    }

                    canvasAssists(geo.size, videoRect)
                    slots.canvasDetails(
                        .init(
                            canvas: geo.size, feed: videoRect, zoom: zoom,
                            chromeVisible: chromeVisible, assistExpanded: assistMode))
                }
                .ignoresSafeArea()

                if !isClipReady || loadError != nil {
                    loadingOverlay
                }

                GeometryReader { geometry in
                    let layout = MonitorPlaybackLayout(
                        width: geometry.size.width, height: geometry.size.height,
                        tablet: UIDevice.current.userInterfaceIdiom == .pad)
                    let portrait = layout.portrait
                    let safe = Self.safeArea(
                        geometry.safeAreaInsets, scene: windowGeometry.safeArea)
                    let sideInset = max(safe.leading, safe.trailing)
                    let corner = FieldMonitorLayout(
                        width: geometry.size.width, height: geometry.size.height,
                        safeArea: MonitorSafeArea(
                            top: safe.top, leading: safe.leading,
                            bottom: safe.bottom, trailing: safe.trailing),
                        topControlInset: windowGeometry.topControlInset
                    ).lock
                    let backX = portrait ? safe.leading + 22 : CGFloat(corner.x)
                    let backY =
                        portrait
                        ? safe.top + windowGeometry.topControlInset + 20 : CGFloat(corner.y)
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            if chromeVisible {
                                VStack(spacing: 0) {
                                    topBar(portrait: portrait)
                                    slots.headerAccessory()
                                }
                                .padding(
                                    .leading,
                                    max(sideInset + 28, backX + CGFloat(corner.width) + 12)
                                )
                                .padding(.trailing, sideInset + 28)
                                .padding(.top, backY)
                                .padding(.bottom, 18)
                                .background(
                                    LinearGradient(
                                        colors: [.black.opacity(0.7), .clear],
                                        startPoint: .top, endPoint: .bottom))
                            }
                            Spacer(minLength: 0)
                            if chromeVisible, let toast = value.toast { toastView(toast) }
                            if chromeVisible {
                                bottomBar(portrait: portrait)
                                    .padding(.horizontal, sideInset)
                                    .padding(.bottom, safe.bottom)
                            }
                            if !chromeVisible {
                                HStack {
                                    Spacer()
                                    restoreChromeButton
                                }
                                .padding(.trailing, sideInset + 12)
                                .padding(.bottom, safe.bottom + 12)
                            }
                        }
                        if chromeVisible {
                            MonitorChromeButton(
                                MonitorPlaybackCopy.backToMedia,
                                size: CGSize(width: corner.width, height: corner.height),
                                action: dismissPlayback
                            ) {
                                MonitorIcon.chevronLeft.frame(
                                    width: corner.width * 29 / 54, height: corner.height * 29 / 54)
                            }
                            .accessibilityIdentifier("monitor.playback.back")
                            .position(
                                x: backX + CGFloat(corner.width) / 2,
                                y: backY + CGFloat(corner.height) / 2)
                            if isConformPresented {
                                conformPanel
                                    .frame(maxWidth: min(480, geometry.size.width - 24))
                                    .padding(.horizontal, 12).padding(.bottom, portrait ? 174 : 116)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        if isInfoPresented {
                            MonitorClipInfoPanel(rows: value.metadata) { isInfoPresented = false }
                                .frame(width: layout.inspectorWidth)
                                .padding(.trailing, sideInset + 12)
                                .padding(.top, safe.top + windowGeometry.topControlInset + 12)
                                .padding(.bottom, safe.bottom + 12)
                                .frame(
                                    maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing
                                )
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: isInfoPresented)
                    .animation(.easeInOut(duration: 0.22), value: isConformPresented)
                    .animation(.easeInOut(duration: 0.22), value: chromeVisible)
                }
                .ignoresSafeArea()
                .zIndex(2)
                if chromeVisible {
                    playbackAssistOverlay
                        .zIndex(3)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: value.item)
        }

        private func topBar(portrait: Bool) -> some View {
            let arrangement =
                portrait
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            return arrangement {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.title).font(MonitorTheme.font(13, weight: .semibold))
                            .foregroundStyle(MonitorTheme.text).lineLimit(1)
                            .accessibilityIdentifier("monitor.playback.title")
                        Text(value.subtitle).font(MonitorTheme.font(9.5)).foregroundStyle(
                            MonitorTheme.muted
                        )
                        .lineLimit(portrait ? 2 : 1)
                        if let source = value.source {
                            Text(source).font(MonitorTheme.font(8, weight: .bold)).tracking(
                                0.5
                            )
                            .foregroundStyle(MonitorTheme.secondary).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    slots.headerActionAccessory()
                    Button {
                        withItem { actions.favorite($0) }
                    } label: {
                        MonitorPlaybackChip {
                            MonitorIcon.star.view(filled: value.favorite)
                                .foregroundStyle(
                                    value.favorite
                                        ? MonitorTheme.edrSRGB(
                                            red: 0.914, green: 0.674, blue: 0.208,
                                            gain: MonitorTheme.hdrGain) : MonitorTheme.secondary)
                        }
                    }
                    .buttonStyle(MonitorButtonStyle()).accessibilityLabel(
                        MonitorPlaybackCopy.favorite)
                    Button {
                        isInfoPresented.toggle()
                    } label: {
                        MonitorPlaybackChip(active: isInfoPresented) { MonitorIcon.info }
                    }
                    .buttonStyle(MonitorButtonStyle()).accessibilityLabel(
                        MonitorPlaybackCopy.clipInformation)
                    shareTransportButton(compact: portrait)
                    if actions.delete != nil || actions.deletionConfirmation != nil { deleteButton }
                }
                .frame(maxWidth: portrait ? .infinity : nil, alignment: .trailing)
                .fixedSize(horizontal: !portrait, vertical: true)
            }
        }

        private func bottomBar(portrait: Bool) -> some View {
            playbackTransportBar(portrait: portrait)
                .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 860 : 630)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 5)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.78), location: 0),
                            .init(color: .black.opacity(0.4), location: 0.62),
                            .init(color: .clear, location: 1),
                        ], startPoint: .bottom, endPoint: .top)
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.onAppear { onBarFrame(proxy.frame(in: .global)) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in
                                onBarFrame(frame)
                            }
                    }
                }
        }

        private func playbackTransportBar(portrait: Bool) -> some View {
            VStack(spacing: 2) {
                HStack {
                    Text(value.positionLabel)
                        .font(MonitorTheme.font(11, weight: .bold)).foregroundStyle(
                            MonitorTheme.text)
                    Spacer()
                    Text(value.durationLabel).font(MonitorTheme.font(11)).foregroundStyle(
                        MonitorTheme.secondary)
                }
                .monospacedDigit().shadow(color: .black, radius: 4)
                MonitorPlaybackScrubControl(value: value, actions: actions)
                let arrangement =
                    portrait
                    ? AnyLayout(VStackLayout(spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
                arrangement {
                    if !portrait { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    HStack(spacing: 8) {
                        transportButton(.skipBack) { seek(by: -15) }
                            .accessibilityLabel(MonitorPlaybackCopy.backFifteen)
                        transportButton(
                            reachedEnd ? .rotateCw : isPlaying ? .pause : .play, size: 26
                        ) {
                            if reachedEnd { restartPlayback() } else { togglePlay() }
                        }
                        .accessibilityLabel(
                            MonitorPlaybackCopy.transport(
                                reachedEnd: reachedEnd, playing: isPlaying))
                        transportButton(.skipForward) { seek(by: 15) }
                            .accessibilityLabel(MonitorPlaybackCopy.forwardFifteen)
                    }
                    HStack(spacing: 8) {
                        conformButton
                        actionToggle(.volumeX, .volume2, on: isMuted) { toggleMute() }
                            .accessibilityLabel(MonitorPlaybackCopy.muteToggle(muted: isMuted))
                        if value.loopAvailable {
                            Button {
                                withItem { actions.loop($0, !value.looping) }
                            } label: {
                                MonitorPlaybackChip(active: isLooping) { MonitorIcon.repeat }
                            }
                            .buttonStyle(MonitorButtonStyle()).accessibilityLabel(
                                MonitorPlaybackCopy.loop
                            )
                            .accessibilityValue(MonitorPlaybackCopy.toggleValue(isLooping))
                        }
                        cleanViewButton
                    }
                    .frame(maxWidth: .infinity, alignment: portrait ? .center : .trailing)
                }
            }
        }

        private var deleteButton: some View {
            Button {
                cancelDeleteConfirmation()
                if let capture = actions.deletionConfirmation, let item = value.item {
                    capturedDeletion = capture.capture(item)
                    capturedDeletionActions = capturedDeletion == nil ? nil : capture
                    isDeleteConfirmPresented = capturedDeletion != nil
                } else {
                    deleteItem = value.item
                    isDeleteConfirmPresented = deleteItem != nil
                }
            } label: {
                MonitorPlaybackChip(destructive: true) { MonitorIcon.trash }
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel(MonitorPlaybackCopy.delete)
            .confirmationDialog(
                capturedDeletion?.title ?? MonitorPlaybackCopy.deleteConfirmationTitle,
                isPresented: $isDeleteConfirmPresented,
                titleVisibility: .visible
            ) {
                Button(MonitorPlaybackCopy.deleteConfirm, role: .destructive) {
                    if let captured = capturedDeletion, let typed = capturedDeletionActions {
                        capturedDeletion = nil; capturedDeletionActions = nil; deleteItem = nil
                        if typed.isCurrent(captured.id) { typed.confirm(captured.id) }
                        else { typed.cancel(captured.id) }
                    } else {
                        let admitted = deleteItem; deleteItem = nil
                        if let admitted { actions.delete?(admitted) }
                    }
                }
                // Dismissal settles the request through isDeleteConfirmPresented below.
                Button(MonitorPlaybackCopy.deleteCancel, role: .cancel) {}
            } message: {
                if let message = capturedDeletion?.message { Text(message) }
            }
            .onChange(of: isDeleteConfirmPresented) { _, shown in
                if !shown { cancelDeleteConfirmation() }
            }
        }

        private func cancelDeleteConfirmation() {
            let captured = capturedDeletion, outgoing = capturedDeletionActions
            capturedDeletion = nil; capturedDeletionActions = nil; deleteItem = nil; isDeleteConfirmPresented = false
            if let captured { outgoing?.cancel(captured.id) }
        }

        @ViewBuilder
        private func clipNavigationArrows(in videoRect: CGRect) -> some View {
            if canGoPrevious {
                Button {
                    goToAdjacent(offset: -1)
                } label: {
                    MonitorIcon.chevronLeft
                        .frame(width: 13, height: 13)
                        .foregroundStyle(MonitorTheme.accent)
                        .frame(width: 32, height: 32)
                        .monitorGlass(in: Circle(), density: .compact)
                }
                .buttonStyle(MonitorButtonStyle())
                .position(x: videoRect.minX + 22, y: videoRect.midY)
                .accessibilityLabel(MonitorPlaybackCopy.previousClip)
            }
            if canGoNext {
                Button {
                    goToAdjacent(offset: 1)
                } label: {
                    MonitorIcon.chevronRight
                        .frame(width: 13, height: 13)
                        .foregroundStyle(MonitorTheme.accent)
                        .frame(width: 32, height: 32)
                        .monitorGlass(in: Circle(), density: .compact)
                }
                .buttonStyle(MonitorButtonStyle())
                .position(x: videoRect.maxX - 22, y: videoRect.midY)
                .accessibilityLabel(MonitorPlaybackCopy.nextClip)
            }
        }

        private var loadingOverlay: some View {
            ZStack {
                Color.black.opacity(0.72)
                VStack(spacing: 12) {
                    if loadError == nil {
                        if let progress = value.progress,
                            progress > 0, progress < 1
                        {
                            ProgressView(value: progress)
                                .tint(MonitorTheme.accent)
                                .frame(width: 120)
                        } else {
                            ProgressView().tint(MonitorTheme.accent)
                        }
                    }
                    Text(loadError ?? loadingCopy)
                        .font(MonitorTheme.font(14, weight: .medium))
                        .foregroundStyle(MonitorTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .monitorGlass(
                    in: RoundedRectangle(cornerRadius: MonitorTheme.radius), density: .information)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        private var loadingCopy: String {
            if value.progress != nil {
                return "Buffering from camera…"
            }
            return "Preparing playback…"
        }

        private var playbackAssistOverlay: some View {
            GeometryReader { proxy in
                let safeArea = Self.safeArea(
                    proxy.safeAreaInsets, scene: windowGeometry.safeArea)
                let size = Self.canvasSize(
                    layoutSize: proxy.size, safeArea: safeArea,
                    screenSize: windowGeometry.validSize)
                let presentation = FieldMonitorLayout(
                    width: size.width, height: size.height,
                    safeArea: MonitorSafeArea(
                        top: safeArea.top, leading: safeArea.leading,
                        bottom: safeArea.bottom, trailing: safeArea.trailing),
                    showsValues: true,
                    topControlInset: windowGeometry.topControlInset)
                tools(
                    .init(presentation: presentation, safeTop: safeArea.top, expanded: $assistMode)
                )
                .frame(width: size.width, height: size.height)
            }
            .ignoresSafeArea()
        }

        private var conformButton: some View {
            let availability = MonitorConformPreview.availability(for: conformSource)
            return Button {
                isConformPresented.toggle()
            } label: {
                MonitorPlaybackChip(active: conformTarget != nil || isConformPresented) {
                    MonitorIcon.timer
                }
            }
            .buttonStyle(MonitorButtonStyle()).disabled(!availability.isAvailable)
            .accessibilityLabel(MonitorPlaybackCopy.conformPreview)
        }

        private var conformPanel: some View {
            let availability = MonitorConformPreview.availability(for: conformSource)
            let rate = conformSource.captureRate ?? 0
            let labels =
                [MonitorPlaybackCopy.realTime]
                + availability.targets.map {
                    MonitorConformPreview.targetLabel(captureRate: rate, targetRate: $0)
                }
            return VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MonitorPlaybackCopy.conformTitle).font(
                            MonitorTheme.font(9, weight: .bold)
                        ).tracking(
                            1.8)
                        Text(MonitorPlaybackCopy.conformSubtitle(captureRate: rate))
                            .font(MonitorTheme.font(9)).foregroundStyle(MonitorTheme.muted)
                    }
                    Spacer()
                    Button {
                        isConformPresented = false
                    } label: {
                        MonitorIcon.x.frame(width: 12, height: 12).frame(width: 44, height: 44)
                    }.buttonStyle(MonitorButtonStyle()).accessibilityLabel(
                        MonitorPlaybackCopy.closeConformPreview)
                }
                MonitorValueDrum(
                    options: labels,
                    selection: Binding(
                        get: {
                            conformTarget.map {
                                MonitorConformPreview.targetLabel(captureRate: rate, targetRate: $0)
                            } ?? MonitorPlaybackCopy.realTime
                        },
                        set: { label in
                            guard let index = labels.firstIndex(of: label) else { return }
                            withItem {
                                actions.conform(
                                    $0, index == 0 ? nil : availability.targets[index - 1])
                            }
                        }), isInteractive: availability.isAvailable, haptics: value.haptics)
                if let reason = availability.unavailableReason {
                    Text(reason).font(MonitorTheme.font(9)).foregroundStyle(MonitorTheme.muted)
                }
                if conformTarget != nil {
                    Text(MonitorConformPreview.audioLabel).font(MonitorTheme.font(9))
                        .foregroundStyle(
                            MonitorTheme.muted)
                }
            }
            .padding(14).monitorGlass(in: RoundedRectangle(cornerRadius: 14), density: .expanded)
        }

        private var cleanViewButton: some View {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { chromeVisible = false }
            } label: {
                MonitorPlaybackChip { MonitorIcon.maximize }
            }
            .buttonStyle(MonitorButtonStyle()).accessibilityLabel(MonitorPlaybackCopy.hideControls)
            .accessibilityHint(MonitorPlaybackCopy.hideControlsHint)
        }

        private var restoreChromeButton: some View {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { chromeVisible = true }
            } label: {
                MonitorPlaybackChip { MonitorIcon.minimize }
            }
            .buttonStyle(MonitorButtonStyle()).accessibilityLabel(MonitorPlaybackCopy.showControls)
        }

        private func shareTransportButton(compact: Bool) -> some View {
            Button {
                withItem { actions.share($0) }
            } label: {
                MonitorPlaybackChip(
                    title: compact ? nil : MonitorPlaybackCopy.shareTitle, active: true
                ) {
                    MonitorIcon.share
                }
            }
            .buttonStyle(MonitorButtonStyle()).accessibilityLabel(MonitorPlaybackCopy.share)
            .disabled(!value.shareEnabled)
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { slots.onShareButtonFrame(proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            slots.onShareButtonFrame(frame)
                        }
                }
            }
        }

        private func toastView(_ message: String) -> some View {
            Text(message)
                .font(MonitorTheme.font(13, weight: .medium))
                .foregroundStyle(MonitorTheme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .monitorGlass(in: Capsule(), density: .compact)
                .padding(.bottom, 8)
                .transition(.opacity)
        }

        private func transportButton(
            _ icon: MonitorIcon, size: CGFloat = 18, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                icon.frame(width: size, height: size).foregroundStyle(MonitorTheme.text)
                    .frame(
                        width: MonitorPlaybackLayout.transportSize,
                        height: MonitorPlaybackLayout.transportSize
                    ).contentShape(Circle())
                    .shadow(color: .black.opacity(0.9), radius: 5)
            }
            .buttonStyle(MonitorButtonStyle())
        }

        private func actionToggle(
            _ onIcon: MonitorIcon, _ offIcon: MonitorIcon, on: Bool, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                MonitorPlaybackChip(active: on) { on ? onIcon : offIcon }
            }
            .buttonStyle(MonitorButtonStyle())
        }

        private var playbackVideoGesture: some Gesture {
            SimultaneousGesture(
                SimultaneousGesture(playbackMagnificationGesture, playbackPanGesture),
                chromeSwipeGesture
            )
        }

        private var playbackFrameTapGesture: AnyGesture<Void> {
            guard value.doubleTapResetsZoom else {
                return AnyGesture(TapGesture().onEnded { handleFrameTap() })
            }
            return AnyGesture(
                TapGesture(count: 2).onEnded {
                    if value.doubleTapResetsZoom { zoom.reset() }
                }.exclusively(before: TapGesture().onEnded { handleFrameTap() }).map { _ in () })
        }

        private var playbackFrameScrubGesture: some Gesture {
            LongPressGesture(minimumDuration: PlaybackFrameScrubMetrics.longPressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($framePointerActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard isClipReady else { return }
                    guard !zoom.isZoomed else { return }
                    switch value {
                    case .first(true):
                        frameScrubPending = true
                    case .second(true, let drag?):
                        if frameScrubPending {
                            beginFrameScrub()
                            frameScrubPending = false
                        }
                        guard isFrameScrubbing else { return }
                        updateFrameScrub(horizontalDelta: drag.translation.width)
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    frameScrubPending = false
                    if frameEditing.end(), isFrameScrubbing { endFrameScrub() }
                }
        }

        private var chromeSwipeGesture: some Gesture {
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard !isFrameScrubbing else { return }
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width) + 8, abs(dy) > 44 else { return }
                    if dy < 0 {
                        withAnimation(.spring(duration: 0.32)) { chromeVisible = true }
                    } else {
                        withAnimation(.spring(duration: 0.32)) { chromeVisible = false }
                    }
                }
        }

        private var playbackMagnificationGesture: some Gesture {
            MagnifyGesture()
                .onChanged { value in
                    if pinchItem == nil { pinchItem = self.value.item }
                    guard pinchItem != nil, pinchItem == self.value.item else { return }
                    if abs(value.magnification - 1) > 0.02 {
                        suppressNextPlaybackTap = true
                        frameScrubPending = false
                    }
                    if self.value.continuousPanBounds {
                        zoom.pinchChangedBounded(
                            magnification: value.magnification,
                            startAnchorX: value.startAnchor.x, startAnchorY: value.startAnchor.y,
                            size: zoomPictureSize, boundsSize: zoomContainerSize,
                            horizontalPresentationScale: self.value.horizontalPresentationScale,
                            verticalPresentationScale: self.value.verticalPresentationScale)
                    } else {
                        zoom.pinchChanged(
                            magnification: value.magnification,
                            startAnchorX: value.startAnchor.x, startAnchorY: value.startAnchor.y,
                            size: zoomContainerSize)
                    }
                }
                .onEnded { _ in
                    let admitted = pinchItem
                    pinchItem = nil
                    guard admitted != nil, admitted == value.item else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom.endPinch(
                            size: zoomContainerSize,
                            horizontalPresentationScale: value.horizontalPresentationScale,
                            verticalPresentationScale: value.verticalPresentationScale)
                    }
                }
        }

        private var playbackPanGesture: some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if panItem == nil { panItem = self.value.item }
                    guard panItem != nil, panItem == self.value.item, zoom.isZoomed else { return }
                    if hypot(value.translation.width, value.translation.height) > 8 {
                        suppressNextPlaybackTap = true
                        frameScrubPending = false
                    }
                    if self.value.continuousPanBounds {
                        zoom.panChangedBounded(
                            translation: value.translation, size: zoomContainerSize,
                            horizontalPresentationScale: self.value.horizontalPresentationScale,
                            verticalPresentationScale: self.value.verticalPresentationScale)
                    } else {
                        zoom.panChanged(translation: value.translation)
                    }
                }
                .onEnded { _ in
                    let admitted = panItem
                    panItem = nil
                    guard admitted != nil, admitted == value.item, zoom.isZoomed else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom.endPan(
                            size: zoomContainerSize,
                            horizontalPresentationScale: value.horizontalPresentationScale,
                            verticalPresentationScale: value.verticalPresentationScale)
                    }
                }
        }

        @ViewBuilder
        private func playbackTransportFlashOverlay(in videoRect: CGRect) -> some View {
            if let playbackFlashIcon {
                playbackFlashIcon
                    .frame(width: 48, height: 48)
                    .foregroundStyle(MonitorTheme.text)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                    .overlay {
                        playbackFlashIcon
                            .frame(width: 48, height: 48)
                            .foregroundStyle(MonitorTheme.accent.opacity(0.28))
                            .blendMode(.overlay)
                    }
                    .opacity(playbackFlashVisible ? 1 : 0)
                    .scaleEffect(playbackFlashVisible ? 1 : 0.86)
                    .animation(
                        .easeOut(duration: PlaybackFlashMetrics.fadeIn), value: playbackFlashVisible
                    )
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .allowsHitTesting(false)
            }
        }

        @ViewBuilder
        private func playbackFrameScrubOverlay(in videoRect: CGRect) -> some View {
            if isFrameScrubbing, duration > 0 {
                let fraction = min(1, max(0, scrubTime / duration))
                let barWidth = max(0, videoRect.width - 32)
                VStack(spacing: 10) {
                    Text(value.positionLabel)
                        .font(MonitorTheme.font(16, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(MonitorTheme.text)
                        .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                    Text("/ \(value.durationLabel)")
                        .font(MonitorTheme.font(11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(MonitorTheme.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .monitorGlass(in: Capsule(), density: .compact)
                .position(x: videoRect.midX, y: videoRect.midY)
                .allowsHitTesting(false)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MonitorTheme.border)
                        .frame(width: barWidth, height: 3)
                    Capsule()
                        .fill(MonitorTheme.accent)
                        .frame(width: max(3, barWidth * fraction), height: 3)
                }
                .position(x: videoRect.midX, y: videoRect.maxY - 18)
                .allowsHitTesting(false)
            }
        }

        private func withItem(_ perform: (MonitorPlaybackItemToken) -> Void) {
            guard let item = value.item else { return }
            perform(item)
        }
        private func togglePlay() { withItem { actions.play($0, !value.playing) } }
        private func restartPlayback() { withItem { actions.restart($0) } }
        private func seek(by delta: Double) { withItem { actions.seekBy($0, delta) } }
        private func toggleMute() { withItem { actions.mute($0, !value.muted) } }
        private func dismissPlayback() {
            cancelEditing(.disappeared)
            actions.back()
        }
        private func goToAdjacent(offset: Int) {
            withItem { actions.adjacent($0, offset) }
        }
        private func beginEditing() {
            guard editing.token == nil, let item = value.item else { return }
            _ = editing.admit(actions.beginScrub(item), item: item)
        }
        private func cancelEditing(_ reason: MonitorEditingCancellation) {
            _ = frameEditing.cancel(pointerIsActive: framePointerActive)
            frameScrubPending = false
            guard let edit = editing.take() else { return }
            isFrameScrubbing = false
            actions.cancelScrub(edit, reason)
        }
        private func beginFrameScrub() {
            guard frameEditing.begin() else { return }
            beginEditing()
            guard editing.token != nil else { return }
            isFrameScrubbing = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        private func updateFrameScrub(horizontalDelta: CGFloat) {
            if let edit = editing.token {
                actions.updateFrameScrub(
                    edit, Double(horizontalDelta), Double(frameScrubVideoWidth))
            }
        }
        private func endFrameScrub() {
            guard let edit = editing.take() else { return }
            isFrameScrubbing = false
            suppressNextPlaybackTap = true
            actions.commitScrub(edit)
        }
        private func handleFrameTap() {
            guard isClipReady, !isFrameScrubbing else { return }
            if suppressNextPlaybackTap {
                suppressNextPlaybackTap = false
                return
            }
            if reachedEnd {
                restartPlayback()
                flash(.play)
            } else {
                let willPlay = !isPlaying
                togglePlay()
                flash(willPlay ? .play : .pause)
            }
        }
        private func flash(_ icon: MonitorIcon) {
            playbackFlashTask?.cancel()
            playbackFlashIcon = icon
            playbackFlashVisible = false
            playbackFlashTask = Task { @MainActor in
                playbackFlashVisible = true
                try? await Task.sleep(for: .seconds(PlaybackFlashMetrics.hold))
                guard !Task.isCancelled else { return }
                playbackFlashVisible = false
                try? await Task.sleep(for: .seconds(PlaybackFlashMetrics.fadeOut))
                guard !Task.isCancelled else { return }
                playbackFlashIcon = nil
            }
        }
        private func updateGeometry(canvas: CGSize, feed: CGRect) {
            frameScrubVideoWidth = feed.width
            zoomPictureSize = feed.size
            zoomContainerSize = value.zoomBoundary == .canvas ? canvas : feed.size
            onGeometry(.init(item: value.item, canvas: canvas, feed: feed, zoom: zoom))
        }
        private static func fit(aspect: Double, in rect: CGRect) -> CGRect {
            let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
            let width = min(rect.width, rect.height * ratio)
            let height = width / ratio
            return CGRect(
                x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        private static func safeArea(_ reported: EdgeInsets, scene: EdgeInsets) -> EdgeInsets {
            .init(
                top: max(reported.top, scene.top), leading: max(reported.leading, scene.leading),
                bottom: max(reported.bottom, scene.bottom),
                trailing: max(reported.trailing, scene.trailing))
        }
        private static func canvasSize(
            layoutSize: CGSize, safeArea: EdgeInsets, screenSize: CGSize?
        ) -> CGSize {
            let restored = CGSize(
                width: layoutSize.width + safeArea.leading + safeArea.trailing,
                height: layoutSize.height + safeArea.top + safeArea.bottom)
            guard let screen = screenSize, screen.width > 1, screen.height > 1 else {
                return restored
            }
            if abs(layoutSize.width - screen.width) < 1
                && abs(layoutSize.height - screen.height) < 1
            {
                return layoutSize
            }
            return CGSize(
                width: max(restored.width, screen.width),
                height: max(restored.height, screen.height))
        }
    }
    private struct MonitorPlaybackScrubControl: View {
        let value: MonitorPlaybackPresentation
        let actions: MonitorPlaybackActions
        @State private var editing = MonitorPlaybackEditing()
        var body: some View {
            MonitorPlaybackScrubber(
                progress: value.position, duration: value.duration,
                bufferedProgress: value.buffered, interactionIdentity: { AnyHashable(value.item) },
                onScrubbingChanged: { dragging in
                    guard dragging, editing.token == nil, let item = value.item else { return }
                    _ = editing.admit(actions.beginScrub(item), item: item)
                },
                onProgressChange: { time in
                    if let edit = editing.token { actions.updateScrub(edit, time) }
                },
                onSeek: { time in
                    guard let edit = editing.take() else { return }
                    actions.updateScrub(edit, time)
                    actions.commitScrub(edit)
                },
                onCancelled: { reason in
                    guard let edit = editing.take() else { return }
                    actions.cancelScrub(edit, reason)
                })
        }
    }

#endif
