#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineMedia
import SwiftUI
import UIKit

/// What a camera source adds to the shared playback page: the page's native runtime, the item
/// owner over its library, its operations and its per-record values. Everything else (picture,
/// backdrop, delivery cover, share popup, close) is the host's.
@MainActor public protocol MonitorPlaybackPresentationSource: AnyObject {
    associatedtype Payload: Sendable
    associatedtype Look: Sendable
    /// What the share popup presents: the record itself unless the source captures more.
    associatedtype Delivery = MonitorMediaRecord<Payload>
    var presentation: MonitorApplePlaybackPresentation<Payload, Look> { get }
    func makeOwner() -> MonitorOperatorMediaModel<Payload, Look>
    func operations(owner: MonitorOperatorMediaModel<Payload, Look>) -> MonitorOperatorPlaybackOperations<Payload, Look>
    func values(record: MonitorMediaRecord<Payload>, owner: MonitorOperatorMediaModel<Payload, Look>)
        -> MonitorPlaybackSourceValues
    /// Captures the share popup's request when the operator shares `record`; nil refuses it.
    func delivery(record: MonitorMediaRecord<Payload>, owner: MonitorOperatorMediaModel<Payload, Look>)
        -> Delivery?
    /// Work Close must join before the page dismisses (for example a native transfer the
    /// source entered). Nil dismisses at once; the join's result decides whether to dismiss.
    func captureClose(owner: MonitorOperatorMediaModel<Payload, Look>) -> (@MainActor () async -> Bool)?
}

extension MonitorPlaybackPresentationSource where Delivery == MonitorMediaRecord<Payload> {
    public func delivery(record: MonitorMediaRecord<Payload>, owner: MonitorOperatorMediaModel<Payload, Look>)
        -> Delivery? { record }
}

extension MonitorPlaybackPresentationSource {
    public func captureClose(owner: MonitorOperatorMediaModel<Payload, Look>) -> (@MainActor () async -> Bool)? {
        nil
    }
}

/// The app state the playback and photo pages read.
@MainActor public protocol MonitorMediaHost: AnyObject {
    associatedtype Looks: MonitorLookProvider
    var assist: MonitorAssistState<Looks> { get }
    var assistToolUsage: MonitorToolUsage { get set }
    /// The app-scoped delivery owner; it covers playback while it runs or shares.
    var delivery: MonitorDeliveryCoordinator { get }
    /// The bus playback publishes its samples into.
    var frameSamples: LiveFrameSampleBus { get }
    /// The bus the scopes read (a watched relay's while watching).
    var monitorSamples: LiveFrameSampleBus { get }
    var playbackBackdrop: OpenCineAppKitApple.MonitorVideoBackdropRenderer { get }
}

/// App values of the media pages: panel stores, looks, palette, haptics, scope display, the
/// remote destination's name and the native picture host (renderer and HDR configuration).
public struct MonitorMediaPageValues<Palette: LiveChromePalette> {
    public let stores: AssistPanelStores
    public let looks: FalseColorLooks
    public let palette: Palette.Type
    public let haptics: OperatorHaptics
    public let cacheOriginal: @MainActor () -> Bool
    public let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    public let remoteDisplayName: String?
    public let makePictureHost: @MainActor () -> MonitorPlaybackFeedHost

    public init(stores: AssistPanelStores, looks: FalseColorLooks, palette: Palette.Type, haptics: OperatorHaptics,
        cacheOriginal: @escaping @MainActor () -> Bool,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions,
        remoteDisplayName: String?, makePictureHost: @escaping @MainActor () -> MonitorPlaybackFeedHost) {
        self.stores = stores; self.looks = looks; self.palette = palette; self.haptics = haptics
        self.cacheOriginal = cacheOriginal; self.configureDisplay = configureDisplay
        self.remoteDisplayName = remoteDisplayName; self.makePictureHost = makePictureHost
    }
}

/// Optional playback page values an app adds to the shared page; the defaults are the shared
/// page's own.
public struct MonitorPlaybackPageOptions {
    public var signalOptions: MonitorOperatorSignalOptions
    /// The assist tools this source offers in playback; nil offers every shared tool.
    public var availableAssistTools: Set<MonitorAssistSelection>?
    public var initialRatingShadeOpen: Bool
    public var initialChromeVisible: Bool

    public init(signalOptions: MonitorOperatorSignalOptions = .init(),
        availableAssistTools: Set<MonitorAssistSelection>? = nil,
        initialRatingShadeOpen: Bool = false, initialChromeVisible: Bool = true) {
        self.signalOptions = signalOptions; self.availableAssistTools = availableAssistTools
        self.initialRatingShadeOpen = initialRatingShadeOpen; self.initialChromeVisible = initialChromeVisible
    }
}

/// The one playback page of the camera apps: the shared operator screen over a source's item
/// owner, the native picture, the video backdrop, the delivery cover and the share popup.
/// The page is covered (playback paused) while its share popup is up and while the app's
/// delivery covers playback (`MonitorDeliveryCoordinator.coversPlayback`).
public struct MonitorOperatorPlaybackHost<Source: MonitorPlaybackPresentationSource, Host: MonitorMediaHost,
    Palette: LiveChromePalette, Preview: View, LookMenu: View, DeliveryPopup: View>: View {
    public typealias Payload = Source.Payload
    public typealias Look = Source.Look
    private struct Page {
        let source: Source
        let owner: MonitorOperatorMediaModel<Payload, Look>
    }
    private let opening: MonitorMediaGalleryOpen<Payload>
    private let host: Host
    private let values: MonitorMediaPageValues<Palette>
    private let makeSource: @MainActor () -> Source
    private let captureSource: @MainActor () -> MonitorPlaybackAdmission
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    private let deliveryPopup: (Source.Delivery, @escaping () -> Void) -> DeliveryPopup
    private let options: MonitorPlaybackPageOptions
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page?
    @State private var sourceAdmission: MonitorPlaybackAdmission?
    @State private var pictureGeometry: MonitorPlaybackPictureGeometry?
    @State private var delivery: Source.Delivery?

    /// `captureSource` runs once when the page opens and returns the admission of the app
    /// source it opened on; `makeSource` builds the camera source for the page.
    public init(opening: MonitorMediaGalleryOpen<Payload>, host: Host, values: MonitorMediaPageValues<Palette>,
        options: MonitorPlaybackPageOptions = .init(),
        makeSource: @escaping @MainActor () -> Source,
        captureSource: @escaping @MainActor () -> MonitorPlaybackAdmission,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu,
        @ViewBuilder deliveryPopup: @escaping (Source.Delivery, @escaping () -> Void) -> DeliveryPopup) {
        self.opening = opening; self.host = host; self.values = values; self.options = options
        self.makeSource = makeSource; self.captureSource = captureSource
        self.preview = preview; self.lookMenu = lookMenu; self.deliveryPopup = deliveryPopup
    }

    public var body: some View {
        Group {
            if let page {
                player(page)
                    .overlay {
                        if let delivery {
                            deliveryPopup(delivery) { self.delivery = nil }.zIndex(5)
                        }
                    }
                    .overlay {
                        MonitorOperatorDeliveryChrome(model: host.delivery.lifetime, scope: .surface,
                            remoteDisplayName: values.remoteDisplayName)
                    }
            } else { MonitorOperatorMediaUnavailable(close: { dismiss() }) }
        }.onAppear {
            guard page == nil else { return }
            sourceAdmission = captureSource()
            let source = makeSource()
            page = Page(source: source, owner: source.makeOwner())
        }
    }

    private func player(_ page: Page) -> some View {
        let owner = page.owner, source = page.source, presentation = source.presentation
        let host = host
        return MonitorOperatorPlaybackScreen(model: owner, initial: opening,
            assist: host.assist, stores: values.stores, looks: values.looks, palette: values.palette,
            haptics: values.haptics,
            usage: Binding(get: { host.assistToolUsage }, set: { host.assistToolUsage = $0 }),
            cacheOriginal: values.cacheOriginal(),
            deliveryPresented: delivery != nil || host.delivery.coversPlayback,
            operations: source.operations(owner: owner),
            source: { source.values(record: $0, owner: owner) },
            nativeAssists: { playback in
                guard playback.native === presentation.native else { return nil }
                return presentation.assists
            }, readScopes: { host.monitorSamples.displayBundle }, configureDisplay: values.configureDisplay,
            sourceCurrent: { sourceAdmission?.isCurrent() == true },
            close: { close(page) }, share: { record in
                // A refused capture leaves the page uncovered, as it was before the tap.
                guard let captured = source.delivery(record: record, owner: owner) else {
                    owner.setDeliveryPresented(delivery != nil || host.delivery.coversPlayback)
                    return
                }
                delivery = captured
            }, onGeometry: { geometry in
                guard geometry.item == owner.playback?.token else { return }
                pictureGeometry = geometry
            }, initialRatingShadeOpen: options.initialRatingShadeOpen,
            signalOptions: options.signalOptions, availableAssistTools: options.availableAssistTools,
            initialChromeVisible: options.initialChromeVisible,
            picture: { playback, effects in
                nativePicture(presentation, playback: playback, effects: effects)
            }, preview: preview, lookMenu: lookMenu)

            .monitorVideoBackdrop(renderer: host.playbackBackdrop,
                configuration: backdropConfiguration(owner, presentation: presentation),
                enabled: owner.playerVisible && owner.playback?.ready == true, surroundRGB: 0x000000
            ) { [owner, presentation] size in
                guard let playback = owner.playback, let native = presentation.native else { return [] }
                let token = playback.token, samples = host.frameSamples
                let epoch = samples.inspectorSourceEpoch
                // Presentation only: the backdrop asks up to 60 times a second, so it never runs
                // the source's item admission (which may read the file system).
                guard owner.presents(token), let buffer = native.feed.backdropSource() else { return [] }
                let dimensions = displaySize(playback)
                var effects = presentation.projectEffects(host.assist.playbackEffects)
                let rect = DesqueezeAssist.presentationRect(sourceSize: dimensions,
                    in: CGRect(origin: .zero, size: size), effects: effects)
                effects.clipByte = host.frameSamples.exposureCeiling.clipByte(transfer: effects.transfer)
                return [MonitorVideoBackdropSource(buffer: buffer, effects: effects,
                    frame: MonitorVideoBackdropSource.displayedFrame(
                        sourceAspect: dimensions.width / max(1, dimensions.height), effects: effects,
                        in: rect, zoom: pictureGeometry?.zoom.scale ?? 1,
                        offset: pictureGeometry?.zoom.offset ?? .zero), clip: rect, identity: .playback(item: token, epoch: epoch),
                    admission: { [weak owner, weak playback, weak native, weak presentation, weak samples] in
                        guard let owner, let playback, let native, let presentation, let samples else { return false }
                        return owner.presents(token) && playback.token == token && presentation.native === native
                            && samples.inspectorSourceEpoch == epoch
                    })]
            }
    }

    /// Close joins the source's entered work first; a stale join never dismisses a newer page.
    private func close(_ closing: Page) {
        guard let join = closing.source.captureClose(owner: closing.owner) else { dismiss(); return }
        Task { @MainActor in
            guard await join(), page?.source === closing.source else { return }
            dismiss()
        }
    }

    @ViewBuilder private func nativePicture(_ presentation: MonitorApplePlaybackPresentation<Payload, Look>,
        playback: MonitorMediaPlaybackModel<Payload, Look>, effects: MonitorFrameEffects) -> some View {
        if let native = presentation.native {
            MonitorPlaybackLayerView(player: native.player, session: native.feed, makeHost: values.makePictureHost,
                qualificationItemToken: { [weak playback = playback] in
                    guard let playback, playback.isActive, playback.ready else { return nil }
                    return playback.token
                },
                effects: presentation.projectEffects(effects), transfer: effects.transfer,
                sampleBus: host.frameSamples)
        }
    }

    private func displaySize(_ playback: MonitorMediaPlaybackModel<Payload, Look>) -> CGSize {
        if let width = playback.metadata.width, let height = playback.metadata.height {
            return .init(width: width, height: height)
        }
        return PlaybackVideoLayout.size(fromResolution: playback.active?.facts.resolution) ?? .init(width: 16, height: 9)
    }

    private func backdropConfiguration(_ owner: MonitorOperatorMediaModel<Payload, Look>,
        presentation: MonitorApplePlaybackPresentation<Payload, Look>) -> [MonitorVideoBackdropConfiguration] {
        guard let playback = owner.playback, let native = presentation.native else { return [] }
        let dimensions = displaySize(playback)
        return [.init(source: ObjectIdentifier(native.feed),
            generation: Int(truncatingIfNeeded: playback.token.revision),
            effects: presentation.projectEffects(host.assist.playbackEffects),
            geometry: [dimensions.width, dimensions.height, pictureGeometry?.zoom.scale ?? 1,
                pictureGeometry?.zoom.offset.width ?? 0, pictureGeometry?.zoom.offset.height ?? 0])]
    }
}

/// The one photo page of the camera apps: the shared still screen with the share popup and the
/// delivery chrome. The source supplies its loaders, operations and source admission.
public struct MonitorOperatorPhotoHost<Payload: Sendable, Host: MonitorMediaHost, Palette: LiveChromePalette,
    DeliveryPopup: View>: View {
    private let opening: MonitorMediaGalleryOpen<Payload>
    private let library: MonitorMediaLibraryModel<Payload>
    private let host: Host
    private let values: MonitorMediaPageValues<Palette>
    private let loaders: MonitorMediaPictureLoaders<Payload, UIImage>
    private let operations: MonitorMediaGalleryOperations<Payload>
    private let sourceCurrent: @MainActor () -> Bool
    private let deliveryPopup: (MonitorMediaRecord<Payload>, @escaping () -> Void) -> DeliveryPopup
    @Environment(\.dismiss) private var dismiss
    @State private var deliveryRecord: MonitorMediaRecord<Payload>?

    public init(opening: MonitorMediaGalleryOpen<Payload>, library: MonitorMediaLibraryModel<Payload>, host: Host,
        values: MonitorMediaPageValues<Palette>, loaders: MonitorMediaPictureLoaders<Payload, UIImage>,
        operations: MonitorMediaGalleryOperations<Payload>, sourceCurrent: @escaping @MainActor () -> Bool,
        @ViewBuilder deliveryPopup: @escaping (MonitorMediaRecord<Payload>, @escaping () -> Void) -> DeliveryPopup) {
        self.opening = opening; self.library = library; self.host = host; self.values = values
        self.loaders = loaders; self.operations = operations; self.sourceCurrent = sourceCurrent
        self.deliveryPopup = deliveryPopup
    }

    public var body: some View {
        MonitorOperatorPhotoScreen(library: library, record: opening.record, admission: opening.admission,
            assist: host.assist, loaders: loaders, operations: operations,
            haptics: values.haptics, coverPresented: deliveryRecord != nil, sourceCurrent: sourceCurrent,
            close: { dismiss() }, share: { request in
                guard request.isCurrent() else { return }
                deliveryRecord = request.record
            })
        .overlay {
            if let deliveryRecord {
                deliveryPopup(deliveryRecord) { self.deliveryRecord = nil }
            }
        }
        .overlay {
            MonitorOperatorDeliveryChrome(model: host.delivery.lifetime, scope: .surface,
                remoteDisplayName: values.remoteDisplayName)
        }
        .onDisappear { deliveryRecord = nil }
        .onChange(of: library.lifetimeToken) { _, _ in deliveryRecord = nil }
    }
}
#endif
