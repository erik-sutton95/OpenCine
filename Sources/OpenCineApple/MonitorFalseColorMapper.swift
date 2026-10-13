#if canImport(CoreImage) && canImport(os)
import Foundation
import OpenCineMedia
import os

public final class MonitorFalseColorMapper: @unchecked Sendable {
    /// 64³ keyed on encoded luma (not linearized Reinhard IRE). 33³ + the old
    /// tone map quantized high-contrast source values into four bands.
    static let cubeSize = 64

    /// Value key - the old per-frame interpolated-String keys allocated on every preview tick.
    private struct CubeKey: Hashable, Sendable {
        /// `overlayPaintDisplay` = paint pre-compensated for the color-managed
        /// (no-LUT) bake, whose output DeviceRGB-encodes untagged cube results.
        enum Kind: Hashable, Sendable {
            case full, overlayPaint, overlayPaintDisplay, overlayWeight
        }
        var kind: Kind
        var scale: LiveFalseColorScale
        var transfer: MonitorTransfer
        var clipByte: Int
        /// Read through the source-provided Rec.709 look.
        var rec709: Bool
    }

    // This cache belongs to one native source owner. Its latest clip request wins.
    private struct OverlayKey: Hashable, Sendable {
        var scale: LiveFalseColorScale
        var transfer: MonitorTransfer
        var managedRender: Bool
        /// Read: 709 / LOG. Without it a toggle returned the cached overlay forever.
        var rec709: Bool
    }

    public struct OverlayMaps: Sendable {
        public var dimension: Int
        public var paint: Data
        public var weight: Data
        public var clipByte: Int
        public var imageEffectsValue: MonitorOverlayMaps {
            MonitorOverlayMaps(dimension: dimension, paint: paint, weight: weight)
        }
    }

    /// Both caches bound to 6 entries (an operator flips between a couple of scale/mode
    /// pairs; unbounded growth kept every visited 33³ lattice alive for the session).
    private struct Store {
        var generation: UInt64 = 0
        var cubes: [CubeKey: CubeLUT] = [:]
        var cubeOrder: [CubeKey] = []
        var data: [CubeKey: (Int, Data)] = [:]
        var dataOrder: [CubeKey] = []
        var warming: Set<CubeKey> = []
        var overlays: [OverlayKey: OverlayMaps] = [:]
        var overlayOrder: [OverlayKey] = []
        var requestedOverlays: [OverlayKey: Int] = [:]
        var buildingOverlays: Set<OverlayKey> = []

        static func touch(_ order: inout [CubeKey], _ key: CubeKey) {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
        }

        mutating func insertCube(_ key: CubeKey, _ cube: CubeLUT) {
            if cubes.updateValue(cube, forKey: key) == nil {
                cubeOrder.append(key)
            } else {
                Self.touch(&cubeOrder, key)
            }
            while cubeOrder.count > MonitorFalseColorMapper.maxCachedEntries {
                cubes[cubeOrder.removeFirst()] = nil
            }
        }

        mutating func insertData(_ key: CubeKey, _ value: (Int, Data)) {
            if data.updateValue(value, forKey: key) == nil {
                dataOrder.append(key)
            } else {
                Self.touch(&dataOrder, key)
            }
            while dataOrder.count > MonitorFalseColorMapper.maxCachedEntries {
                data[dataOrder.removeFirst()] = nil
            }
        }
    }

    private static let maxCachedEntries = 6
    private let lookCurves: [MonitorTransfer: [Double]]
    public init(lookCurves: [MonitorTransfer: [Double]] = [:]) { self.lookCurves = lookCurves }
    public func reset() {
        store.withLock { state in
            let generation = state.generation &+ 1
            state = Store()
            state.generation = generation
        }
    }
    private let store = OSAllocatedUnfairLock(initialState: Store())
    /// `.userInitiated`: at `.utility` the 64³ lattice starved for seconds behind
    /// 4K decode on device - FALSE looked "missing" on first toggle.
    private let warmQueue = DispatchQueue(label: "opv.false-color-warm", qos: .userInitiated)

    /// Every look input is explicit: the source's Read (709 / LOG) and its live ceiling for
    /// `transfer` (``ScopeExposureCeiling/clipByte(transfer:iso:)`` of that source).
    private func key(
        _ kind: CubeKey.Kind, scale: LiveFalseColorScale, transfer: MonitorTransfer,
        rec709: Bool, clipByte: Int
    ) -> CubeKey {
        CubeKey(kind: kind, scale: scale, transfer: transfer, clipByte: clipByte, rec709: rec709)
    }

    public func cube(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> CubeLUT {
        cachedCube(key(.full, scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte))
    }

    /// Band paint for the compositor overlay. Sampled on **encoded camera codes**.
    public func overlayPaintCube(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> CubeLUT {
        cachedCube(
            key(.overlayPaint, scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte)
        )
    }

    /// Coverage mask for the same overlay. 0 = show the displayed look (LUT or identity).
    public func overlayWeightCube(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> CubeLUT {
        cachedCube(
            key(
                .overlayWeight, scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte
            ))
    }

    /// Cached `CIColorCube` bytes for the compositor. `nil` until the async warm lands:
    /// toggling FALSE used to stall the frame path several hundred ms building the lattice.
    /// `managedRender` selects the display-compensated paint for the color-managed
    /// (no-LUT Limits) bake; the unmanaged NSNull context wants the raw colors.
    public func overlayPaintData(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int,
        managedRender: Bool = false
    ) -> (Int, Data)? {
        overlayPairData(
            scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte,
            managedRender: managedRender
        ).map { ($0.dimension, $0.paint) }
    }

    /// CineStop / Video / IRE full lattice: grayscale base with the painted zones.
    /// Not used on the live path: replacing the identity feed with this cube
    /// was the DeviceRGB contrast shift. Tests still sample it.
    public func fullPaintData(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> (Int, Data)? {
        warmedData(
            key(
                .full, scale: scale, transfer: transfer, rec709: rec709,
                clipByte: clipByte))
    }

    public func overlayWeightData(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> (Int, Data)? {
        overlayPairData(scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte)
            .map { ($0.dimension, $0.weight) }
    }

    /// Paint and mask always come from one exposure snapshot. Keep the last
    /// complete map for this look while a new exposure is warming.
    public func overlayPairData(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int,
        managedRender: Bool = false
    ) -> OverlayMaps? {
        let key = OverlayKey(
            scale: scale, transfer: transfer, managedRender: managedRender,
            rec709: rec709)
        let clip = clipByte
        let request = store.withLock { state -> (OverlayMaps?, Bool, UInt64) in
            let previous = state.overlays[key]
            if previous != nil {
                state.overlayOrder.removeAll { $0 == key }
                state.overlayOrder.append(key)
            }
            if state.buildingOverlays.contains(key) {
                state.requestedOverlays[key] = clip
                return (previous, false, state.generation)
            }
            guard previous?.clipByte != clip else { return (previous, false, state.generation) }
            state.requestedOverlays[key] = clip
            return (previous, state.buildingOverlays.insert(key).inserted, state.generation)
        }
        if request.1 { scheduleOverlay(key, generation: request.2) }
        return request.0
    }

    private func scheduleOverlay(_ key: OverlayKey, generation: UInt64) {
        warmQueue.async { [self] in
            guard let clip = store.withLock({ state -> Int? in
                guard state.generation == generation else { return nil }
                return state.requestedOverlays.removeValue(forKey: key)
            })
            else {
                store.withLock { if $0.generation == generation { _ = $0.buildingOverlays.remove(key) } }
                return
            }
            let paintKey = CubeKey(
                kind: key.managedRender ? .overlayPaintDisplay : .overlayPaint,
                scale: key.scale, transfer: key.transfer, clipByte: clip,
                rec709: key.rec709)
            let weightKey = CubeKey(
                kind: .overlayWeight, scale: key.scale,
                transfer: key.transfer, clipByte: clip, rec709: key.rec709)
            let paint = build(paintKey)
            let weight = build(weightKey)
            let maps = OverlayMaps(
                dimension: paint.size,
                paint: paint.rgbaComponents.withUnsafeBytes { Data($0) },
                weight: weight.rgbaComponents.withUnsafeBytes { Data($0) }, clipByte: clip)
            let again = store.withLock { state in
                guard state.generation == generation else { return false }
                let latest = state.requestedOverlays[key] ?? clip
                if latest == clip || state.overlays[key] == nil {
                    state.overlays[key] = maps
                    state.overlayOrder.removeAll { $0 == key }
                    state.overlayOrder.append(key)
                }
                while state.overlayOrder.count > 3 {
                    state.overlays[state.overlayOrder.removeFirst()] = nil
                }
                if latest != clip, state.overlays[key]?.clipByte != latest { return true }
                state.requestedOverlays[key] = nil
                state.buildingOverlays.remove(key)
                return false
            }
            // One queued request per look; intermediate ISO updates are replaced.
            if again { scheduleOverlay(key, generation: generation) }
        }
    }

    /// Kick the 64³ overlay build before the first FALSE frame. Every scale
    /// paints holes-only over the identity / LUT look - do not warm the full
    /// replace lattice (that remake was the contrast shift).
    /// `clipByte` is the source's ceiling. A caller without a source (an operator toggle)
    /// passes `nil`: that rewarms the look at the clip it last showed, or leaves the first
    /// build to the source's own engine so it never warms a different source's ceiling.
    public func warm(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int?,
        hasLUT _: Bool = false
    ) {
        let look = OverlayKey(
            scale: scale, transfer: transfer, managedRender: false, rec709: rec709)
        guard
            let clip = clipByte
                ?? store.withLock({ $0.requestedOverlays[look] ?? $0.overlays[look]?.clipByte })
        else { return }
        _ = overlayPairData(scale: scale, transfer: transfer, rec709: rec709, clipByte: clip)
    }

    public func bands(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> [LiveFalseColorBand] {
        let clip = LiveColorScience.falseColorClip(
            scale: scale, transfer: transfer, rec709: rec709,
            lookCurve: lookCurves[transfer], clipEncoded: Double(clipByte) / 255)
        return LiveColorScience.falseColorBands(
            scale, transfer: clip.transfer, clipEncoded: clip.ceiling)
    }

    private func cachedCube(_ key: CubeKey) -> CubeLUT {
        let hit = store.withLock { state -> CubeLUT? in
            guard let cube = state.cubes[key] else { return nil }
            Store.touch(&state.cubeOrder, key)
            return cube
        }
        if let hit { return hit }
        // Built outside the lock - a racing duplicate build is harmless and rare.
        let generation = store.withLock { $0.generation }
        let cube = build(key)
        store.withLock { if $0.generation == generation { $0.insertCube(key, cube) } }
        return cube
    }

    /// Frame-path lookup: hit or `nil` plus a one-shot utility-queue warm per key.
    private func warmedData(_ key: CubeKey) -> (Int, Data)? {
        let hit = store.withLock { state -> (Int, Data)? in
            guard let value = state.data[key] else { return nil }
            Store.touch(&state.dataOrder, key)
            return value
        }
        if let hit { return hit }
        let request = store.withLock { ($0.warming.insert(key).inserted, $0.generation) }
        if request.0 {
            let generation = request.1
            warmQueue.async { [self] in
                let cube = cachedCube(key)
                let data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
                store.withLock { state in
                    guard state.generation == generation else { return }
                    state.insertData(key, (cube.size, data))
                    state.warming.remove(key)
                }
            }
        }
        return nil
    }

    /// One science for every false colour cube: the shared lattice, which the live paths and the
    /// non-Apple facades bake through too, with this owner's look curves (A1-48).
    private func build(_ key: CubeKey) -> CubeLUT {
        let lattice = MonitorFalseColorLattice.signal(scale: key.scale, transfer: key.transfer,
            clipByte: key.clipByte, lookCurve: lookCurves[key.transfer], readThroughLook: key.rec709,
            size: Self.cubeSize)
        switch key.kind {
        case .full:
            return lattice.cube(.composite)
        case .overlayPaint:
            return lattice.cube(.paint)
        case .overlayPaintDisplay:
            // The managed bake output-converts linear working space to DeviceRGB, so its paint
            // is stored decoded; the encode then lands each band on its authored colour.
            return lattice.cube(.paint, paintEncoding: .linearSRGB)
        case .overlayWeight:
            // Mask values are consumed in working space, never output-converted.
            return lattice.cube(.weight)
        }
    }
}
#endif
