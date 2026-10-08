#if os(iOS)
import CoreImage.CIFilterBuiltins
import Foundation
import MonitorUI
import OpenCineApple
import OpenCineMedia
import SwiftUI
import UIKit

/// Native pixel work stays below presentation. Roles only choose an immutable native product.
public final class MonitorBackdropRenderer {
    fileprivate static var products: [MonitorBackdropBlurProduct] {
        MonitorGlassDensity.allCases.map { .init(radius: $0.blurRadius, saturation: $0.saturation) }
    }
    private let raster = MonitorBackdropRasterRenderer(products: MonitorBackdropRenderer.products)
    public init() {}
    public func render(canvasSize: CGSize, layers: [MonitorBackdropLayer], surroundRGB: UInt32 = 0x08090A)
        -> MonitorBackdropSnapshot? {
        raster.render(canvasSize: canvasSize, layers: layers.map {
            .init(image: $0.image, frame: $0.frame, clip: $0.clip)
        }, surroundRGB: surroundRGB).map(Self.presentation)
    }
    public func render(canvasSize: CGSize, look: CIImage, frame: CGRect, clip: CGRect,
        lookContext: CIContext, outputColorSpace: CGColorSpace?, surroundRGB: UInt32 = 0x08090A)
        -> MonitorBackdropSnapshot? {
        raster.render(canvasSize: canvasSize, look: look, frame: frame, clip: clip,
            lookContext: lookContext, outputColorSpace: outputColorSpace, surroundRGB: surroundRGB).map(Self.presentation)
    }
    fileprivate static func presentation(_ native: MonitorBackdropRasterSnapshot) -> MonitorBackdropSnapshot {
        var images: [MonitorGlassDensity: CGImage] = [:]
        for role in MonitorGlassDensity.allCases {
            images[role] = native.image(for: .init(radius: role.blurRadius, saturation: role.saturation))
        }
        return .init(canvasSize: native.canvasSize, images: images)
    }
    fileprivate static func rasterSnapshot(_ image: MonitorBackdropSnapshot) -> MonitorBackdropRasterSnapshot {
        var images: [MonitorBackdropBlurProduct: CGImage] = [:]
        for role in MonitorGlassDensity.allCases {
            images[.init(radius: role.blurRadius, saturation: role.saturation)] = image.image(for: role)
        }
        return .init(canvasSize: image.canvasSize, images: images)
    }
}

public struct MonitorVideoBackdropConfiguration: Equatable {
    public var source: ObjectIdentifier
    public var generation: Int
    public var effects: MonitorFrameEffects
    public var geometry: [CGFloat]
    public init(source: ObjectIdentifier, generation: Int, effects: MonitorFrameEffects, geometry: [CGFloat] = []) {
        self.source = source; self.generation = generation; self.effects = effects; self.geometry = geometry
    }
}
public typealias MonitorVideoBackdropSource = OpenCineApple.MonitorVideoBackdropSource

/// The presentation projection shares one lower native job/cache through the view lifetime.
public final class MonitorVideoBackdropRenderer: @unchecked Sendable {
    public typealias Operation = @Sendable (CGSize, [MonitorVideoBackdropSource]) -> MonitorBackdropSnapshot?
    public struct Result {
        public let snapshot: MonitorBackdropSnapshot?
        public let isUnchanged: Bool
        fileprivate let native: OpenCineApple.MonitorVideoBackdropRenderer.Result
    }
    private let producer: OpenCineApple.MonitorVideoBackdropRenderer
    public init(lookCurves: [MonitorTransfer: [Double]],
        cacheEligibility: @escaping OpenCineApple.MonitorVideoBackdropRenderer.CacheEligibility = { _ in true },
        externalLookState: OpenCineApple.MonitorVideoBackdropRenderer.LookState? = nil,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        minimumInterval: @escaping @Sendable () -> Double = { MonitorBackdropRenderValues.minimumInterval },
        operation: Operation? = nil) {
        let nativeOperation: OpenCineApple.MonitorVideoBackdropRenderer.Operation?
        if let operation {
            nativeOperation = { canvas, sources in operation(canvas, sources).map(MonitorBackdropRenderer.rasterSnapshot) }
        } else { nativeOperation = nil }
        producer = .init(products: MonitorBackdropRenderer.products, lookCurves: lookCurves,
            cacheEligibility: cacheEligibility, externalLookState: externalLookState,
            clock: clock, minimumInterval: minimumInterval, operation: nativeOperation)
    }
    public func activate(_ owner: UUID) { producer.activate(owner) }
    public func deactivate(_ owner: UUID) { producer.deactivate(owner) }
    @MainActor public func isCurrent(_ result: Result) -> Bool { producer.isCurrent(result.native) }
    @MainActor public func render(owner: UUID, canvasSize: CGSize, surroundRGB: UInt32 = 0x08090A,
        prepare: @MainActor () -> [MonitorVideoBackdropSource]) async -> Result? {
        guard let native = await producer.render(owner: owner, canvasSize: canvasSize,
            surroundRGB: surroundRGB, prepare: prepare) else { return nil }
        return Result(snapshot: native.snapshot.map(MonitorBackdropRenderer.presentation),
            isUnchanged: native.isUnchanged, native: native)
    }
}

private struct MonitorVideoBackdrop: ViewModifier {
    let renderer: MonitorVideoBackdropRenderer
    let configuration: [MonitorVideoBackdropConfiguration]
    let enabled: Bool
    let surroundRGB: UInt32
    let sources: @MainActor (CGSize) -> [MonitorVideoBackdropSource]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var applicationActive = true
    @State private var globalFrame: CGRect = .zero
    @State private var snapshot: MonitorBackdropSnapshot?
    @State private var renderedKey: WorkKey?
    @State private var owner: UUID?
    @State private var source = MonitorBackdropSource()

    private static let idlePollThreshold = 15
    private static let idleIntervalMultiplier: UInt64 = 6

    private struct WorkKey: Equatable {
        var configuration: [MonitorVideoBackdropConfiguration]
        var frame: CGRect
        var active: Bool
        var surroundRGB: UInt32
    }

    private var key: WorkKey {
        WorkKey(
            configuration: configuration, frame: globalFrame,
            active: enabled && scenePhase == .active && applicationActive && !reduceTransparency,
            surroundRGB: surroundRGB)
    }

    func body(content: Content) -> some View {
        content
            .monitorBackdrop(source: source)
            .onChange(of: key, initial: true) { publish() }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                globalFrame = $0
            }
            .task(id: key) { await refresh(key) }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification)
            ) {
                _ in
                applicationActive = false
                if let owner { renderer.deactivate(owner) }
                snapshot = nil
                publish()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            ) {
                _ in applicationActive = true
            }
            .onDisappear {
                if let owner { renderer.deactivate(owner) }
                snapshot = nil
                publish()
            }
    }

    /// The shared source shows a product only for the key it was rendered for.
    private func publish() {
        let visible = renderedKey == key && key.active ? snapshot : nil
        if source.snapshot != nil || visible != nil { source.snapshot = visible }
        if source.frame != globalFrame { source.frame = globalFrame }
    }

    @MainActor
    private func refresh(_ expected: WorkKey) async {
        guard expected.active, expected.frame.width > 1, expected.frame.height > 1 else { return }
        let identity = UUID()
        owner = identity
        renderer.activate(identity)
        defer {
            renderer.deactivate(identity)
            if owner == identity { owner = nil }
        }
        // A new source picture wakes the loop at once, so the glass follows the
        // feed frame for frame; the timeout only polls a held/paused source or a
        // compressed-layer-only feed with no passive buffer. No thermal slowdown:
        // glass behind the picture must never lag it.
        let wake = MonitorBackdropWake()
        var idlePolls = 0
        while !Task.isCancelled {
            // ponytail: after ~250 ms with nothing new, time out at 10 Hz instead
            // of 60 Hz. Frame wakes are unaffected, so a resumed source is immediate.
            let idle = idlePolls >= Self.idlePollThreshold ? Self.idleIntervalMultiplier : 1
            let intervalNs = MonitorBackdropRenderValues.minimumIntervalNanoseconds * idle
            let started = DispatchTime.now().uptimeNanoseconds
            idlePolls += 1
            if let result = await renderer.render(
                owner: identity, canvasSize: expected.frame.size, surroundRGB: expected.surroundRGB,
                prepare: { sources(expected.frame.size) }),
                !Task.isCancelled, renderer.isCurrent(result)
            {
                if !result.isUnchanged {
                    if result.snapshot != nil || snapshot != nil { idlePolls = 0 }
                    snapshot = result.snapshot
                    renderedKey = expected
                    publish()
                }
            }
            let spent = DispatchTime.now().uptimeNanoseconds &- started
            if spent < intervalNs { await wake.wait(timeoutNs: intervalNs - spent) }
        }
    }
}

extension Notification.Name {
    /// A backdrop source has a new picture. Posted by decoders and playback.
    public static let monitorBackdropSourceAdvanced = Notification.Name(
        "com.opencapture.opc.monitor-backdrop.source-advanced")
}

/// Wakes a backdrop loop on the next source picture, or after a timeout.
/// A picture that lands while a job renders is remembered, not dropped.
@MainActor
private final class MonitorBackdropWake {
    private let observer = MonitorBackdropObserver()
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var generation = 0

    init() {
        // `queue: nil` runs on the poster. A main queue here made the playback pull
        // thread wait on Main every frame (the IOS-2T hang shape).
        observer.token = NotificationCenter.default.addObserver(
            forName: .monitorBackdropSourceAdvanced, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fire() } }
        }
    }


    private func fire() {
        guard let waiter else {
            pending = true
            return
        }
        self.waiter = nil
        waiter.resume()
    }

    func wait(timeoutNs: UInt64) async {
        if pending {
            pending = false
            return
        }
        generation += 1
        let expected = generation
        await withCheckedContinuation { continuation in
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard let self, self.generation == expected, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.resume()
            }
        }
    }
}

extension View {
    public func monitorVideoBackdrop(
        renderer: MonitorVideoBackdropRenderer,
        configuration: [MonitorVideoBackdropConfiguration], enabled: Bool,
        surroundRGB: UInt32 = 0x08090A,
        sources: @escaping @MainActor (CGSize) -> [MonitorVideoBackdropSource]
    ) -> some View {
        modifier(
            MonitorVideoBackdrop(
                renderer: renderer, configuration: configuration, enabled: enabled,
                surroundRGB: surroundRGB, sources: sources
            ))
    }
}

extension MonitorVideoBackdropSource {
    /// Fill sizes the native host using the source aspect first. De-squeeze
    /// subsequently fits its wider/taller output inside that same host; it must
    /// not enlarge or crop the host a second time.
    public static func displayedFrame(
        sourceAspect: CGFloat, effects: MonitorFrameEffects, in rect: CGRect,
        fill: Bool = false, zoom: CGFloat = 1, offset: CGSize = .zero
    ) -> CGRect {
        let host = fill ? fittedFrame(aspect: sourceAspect, in: rect, fill: true) : rect
        let aspect =
            sourceAspect
            * (effects.desqueezeHorizontal ? effects.desqueezeFactor : 1 / effects.desqueezeFactor)
        return fittedFrame(aspect: aspect, in: host, zoom: zoom, offset: offset)
    }

    /// Fit/fill and zoom are applied in canvas coordinates before panel clipping.
    public static func fittedFrame(
        aspect: CGFloat, in rect: CGRect, fill: Bool = false,
        zoom: CGFloat = 1, offset: CGSize = .zero
    ) -> CGRect {
        let ratio = max(0.001, aspect)
        let width =
            fill ? max(rect.width, rect.height * ratio) : min(rect.width, rect.height * ratio)
        let size = CGSize(width: width * zoom, height: width / ratio * zoom)
        return CGRect(
            x: rect.midX - size.width / 2 + offset.width,
            y: rect.midY - size.height / 2 + offset.height,
            width: size.width, height: size.height)
    }
}

/// The notification registration has one retained lifetime without a mutable global.
private final class MonitorBackdropObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
#endif
