import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor
@Suite struct MonitorAssistStateTests {
    private func storage() throws -> (UserDefaults, String) {
        let domain = "opencine-assist-state-tests." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: domain)), domain)
    }
    private var keys: MonitorAssistPreferenceKeys {
        .init(assist: "assist", cleanPins: "pins", playback: "playback")
    }
    private var allowed: [MonitorAssistSelection] {
        MonitorAssistTool.allCases.filter { $0 != .evMeter }.map(MonitorAssistSelection.init)
    }

    /// Kotlin mirror: MonitorAssistStateBehaviorTest `declaredDefaultsSeedAFreshStateAndEachReset`
    /// and `savedValuesWinOverDeclaredDefaults` (ZAA-227, ZAA-228).
    @Test func declaredDefaultsSeedAFreshStateAndSavedValuesWin() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let standard = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(standard.defaults == .standard)
        #expect(standard.zebraHighlightIRE == 99 && standard.crushClipCompensation == .zero)

        let nikon = MonitorAssistDefaults(zebraHighlightIRE: 100, crushClipCompensation: .quarter)
        let fresh = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed,
            defaults: nikon)
        #expect(fresh.zebraHighlightIRE == 100 && fresh.crushClipCompensation == .quarter)

        standard.persist()
        let saved = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed,
            defaults: nikon)
        #expect(saved.zebraHighlightIRE == 99 && saved.crushClipCompensation == .zero)

        // A snapshot from before the compensation was saved falls back to the declared default.
        let stored = try #require(defaults.data(forKey: "assist"))
        var object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        object["crushClipCompensation"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "assist")
        let older = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed,
            defaults: nikon)
        #expect(older.crushClipCompensation == .quarter)
    }

    @Test func pinsPlaybackAndCoveredScopesHaveOneIndependentOwner() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        state.toggle(.waveform)
        state.toggle(.peaking)
        state.clean = true
        #expect(state.waveform && !state.effects.waveform && state.effects.peaking)
        state.toggleCleanViewPin(.waveform)
        #expect(state.effects.waveform && state.waveform)
        state.togglePlayback(.zebra)
        #expect(state.playbackEffects.zebra && !state.zebra)
        state.liveCovered = true
        #expect(!state.effects.waveform && state.effects.peaking)
        state.configureTool = .waveform
        #expect(state.effects.waveform)
        state.inspectorSceneActive = false
        #expect(!state.effects.waveform)
        state.toggleCleanViewPin(.evMeter)
        #expect(!state.cleanViewPinnedTools.contains(.evMeter))
        let reloaded = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(
            reloaded.waveform && reloaded.peaking
                && reloaded.cleanViewPinnedTools.contains(.waveform))
        #expect(reloaded.playbackVisibleTools == [.zebra] && !reloaded.zebra)
        let other = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults,
            keys: .init(assist: "other", cleanPins: "otherPins", playback: "otherPlayback"),
            cleanPinCases: allowed)
        #expect(!other.waveform && other.playbackVisibleTools.isEmpty)
    }

    @Test func legacySelectionsDoNotExpandTheCurrentCatalog() throws {
        guard #available(macOS 14, *) else { return }
        #expect(MonitorAssistTool.allCases.count == 18)
        #expect(
            MonitorAssistSelection.allCases.map(\.rawValue).prefix(18)
                == MonitorAssistTool.allCases.map(\.rawValue)[...])
        #expect(MonitorAssistSelection(rawValue: "PLAY") == .instantReview)
        #expect(MonitorAssistSelection(rawValue: "MAG") == .magnification)
        #expect(MonitorAssistSelection(rawValue: "UNKNOWN") == nil)
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        state.toggle(.instantReview)
        state.toggle(.magnification)
        let restored = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(restored.instantReview && !restored.isOn(.magnification))
        let snapshot = try JSONDecoder().decode(
            MonitorAssistSnapshot.self, from: #require(state.encodedSnapshot()))
        #expect(snapshot.tools == ["LUT", "PLAY"])
    }

    @Test func sharedCubePreparationKeepsInspectorAndMainEnablementIndependent() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = StateTestLooks()
        let state = MonitorAssistState(
            looks: looks, storage: defaults, keys: keys, cleanPinCases: allowed)
        let nominal = try #require(state.exportCube(bakeExposure: false))
        state.lutEnabled = false
        state.refreshLUTCube()
        #expect(state.effects.lutDimension == 0 && state.exportCube(bakeExposure: false) == nil)
        state.waveform = true
        state.mirrorVertical = true
        let preview = state.inspectorImageOptions(tool: .peaking, transfer: .hdr, clipByte: 227)
        #expect(preview.peaking && !preview.waveform && !preview.zebra && !preview.inspectorSample)
        #expect(preview.transfer == .hdr && preview.resolvedClipByte == 227)
        #expect(state.waveform && !state.peaking && state.effects.lutDimension == 0)
        let mirror = state.inspectorImageOptions(tool: .mirror, transfer: .rec709, clipByte: 255)
        #expect(mirror.mirror && mirror.mirrorVertical && !state.mirror)
        let inspectorEffects = state.inspectorImageEffects(
            tool: .lut, transfer: .rec709, clipByte: 255)
        #expect(inspectorEffects.lutDimension == 2 && !state.lutEnabled)
        let first = state.inspectorLUT(transfer: .rec709)
        #expect(first.dimension == 2 && !first.rgba.isEmpty && !state.lutEnabled)
        looks.selection = 1
        let second = state.inspectorLUT(transfer: .rec709)
        #expect(first.rgba != second.rgba)
        state.armLastLUT()
        state.nudgeLUTExposure(-0.5)
        #expect(state.lutExposureStops == -0.5 && state.effects.lutDimension == 2)
        #expect(state.exportCube(bakeExposure: false) != nominal)
        #expect(state.exportCube(bakeExposure: true) != state.exportCube(bakeExposure: false))
    }

    @Test func sourceCalibrationAndBakeCurveAreExplicitMediaInputs() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = StateTestLooks()
        looks.transfer = .dlogm
        looks.bakeTransfer = .dlog
        looks.referenceClipByte = 223
        let state = MonitorAssistState(
            looks: looks, storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(state.effects.transfer == .dlogm && state.effects.resolvedClipByte == 223)
        state.nudgeLUTExposure(-1)
        let expected = try #require(looks.cube).preparedForExport(
            bakeExposure: true, stops: -1, transfer: .dlog)
        #expect(state.exportCube(bakeExposure: true) == expected)
    }

    /// Product ruling 2026-10-16: false colour, zebra and LUT exposure read the source curve. While
    /// it is unknown (DJI before its first colour report, Luna Dolby Vision) they are neither offered
    /// nor drawn and the LUT bakes without input exposure; the operator's choices survive, and the
    /// tools return without any operator action once the curve is reported.
    @Test func curveToolsWaitForAKnownSourceCurveAndReturnOnTheirOwn() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = StateTestLooks()
        looks.sourceTransfer = nil
        let state = MonitorAssistState(
            looks: looks, storage: defaults, keys: keys, cleanPinCases: allowed)
        state.toggle(.falseColor)
        state.toggle(.zebra)
        state.toggle(.peaking)
        state.nudgeLUTExposure(1)
        #expect(!state.sourceCurveKnown)
        #expect(state.falseColor && state.zebra && state.lutExposureStops == 1)
        #expect(!state.effects.falseColor && !state.effects.zebra && state.effects.peaking)
        #expect(!state.offers(.falseColor) && !state.offers(.zebra))
        #expect(state.offers(.peaking) && state.offers(.lut) && state.offers(.waveform))
        let cube = try #require(looks.cube)
        #expect(state.exportCube(bakeExposure: true)
            == cube.preparedForExport(bakeExposure: true, stops: 0, transfer: .rec709))

        looks.sourceTransfer = .dlog
        #expect(state.sourceCurveKnown)
        #expect(state.effects.falseColor && state.effects.zebra)
        #expect(state.offers(.falseColor) && state.offers(.zebra))
        #expect(state.exportCube(bakeExposure: true)
            == cube.preparedForExport(bakeExposure: true, stops: 1, transfer: .rec709))
    }

    /// The curve-reading tools are exactly false colour and zebra; every other tool is offered alike.
    @Test func onlyFalseColourAndZebraReadTheSourceCurve() {
        #expect(MonitorAssistSelection.readsSourceCurve == [.falseColor, .zebra])
    }

    @Test func explicitToggleSideEffectObservesDonorLiveAndPlaybackPersistenceOrder() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        var events: [String] = []
        weak var observed: MonitorAssistState<StateTestLooks>?
        let state = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults,
            keys: keys, cleanPinCases: allowed,
            onToggle: { tool, enabled in
                guard let current = observed else {
                    Issue.record("Missing current state")
                    return
                }
                if events.count < 2 {
                    #expect(current.isOn(tool) == enabled)
                    let data = defaults.data(forKey: self.keys.assist)
                    let persisted = data.flatMap {
                        try? JSONDecoder().decode(MonitorAssistSnapshot.self, from: $0)
                    }
                    #expect((persisted?.tools.contains(tool.rawValue) ?? false) == !enabled)
                } else {
                    #expect(current.isPlaybackVisible(tool) == enabled)
                    #expect(
                        (defaults.array(forKey: self.keys.playback) as? [String] ?? []).contains(
                            tool.rawValue) == enabled)
                }
                events.append("\(tool.rawValue):\(enabled)")
            })
        observed = state
        state.toggle(.falseColor)
        state.toggle(.falseColor)
        state.togglePlayback(.falseColor)
        state.togglePlayback(.falseColor)
        #expect(events == ["FALSE:true", "FALSE:false", "FALSE:true", "FALSE:false"])
        state.falseColor = true
        state.clean = true
        state.toggleCleanViewPin(.falseColor)
        state.persist()
        state.togglePlayback(.evMeter)
        #expect(events.count == 4)
    }

    @Test func nilToggleSideEffectRetainsStoredSchemasAndNamespaceIsolation() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let originalKeys = keys
        let observerKeys = MonitorAssistPreferenceKeys(
            assist: "observed", cleanPins: "observedPins", playback: "observedPlayback")
        var count = 0
        let plain = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults,
            keys: originalKeys, cleanPinCases: allowed)
        let observed = MonitorAssistState(
            looks: StateTestLooks(), storage: defaults,
            keys: observerKeys, cleanPinCases: allowed, onToggle: { _, _ in count += 1 })
        for state in [plain, observed] {
            state.toggle(.falseColor)
            state.toggle(.peaking)
            state.togglePlayback(.zebra)
            state.togglePlayback(.zebra)
        }
        let plainJSON =
            try JSONSerialization.jsonObject(
                with: #require(defaults.data(forKey: originalKeys.assist))) as? NSDictionary
        let observedJSON =
            try JSONSerialization.jsonObject(
                with: #require(defaults.data(forKey: observerKeys.assist))) as? NSDictionary
        #expect(plainJSON == observedJSON && count == 4)
        #expect(defaults.array(forKey: originalKeys.playback) as? [String] == [])
        #expect(defaults.array(forKey: observerKeys.playback) as? [String] == [])
        #expect(plainJSON?["onToggle"] == nil)
        plain.toggle(.falseColor)
        #expect(count == 4 && observed.falseColor)
    }

    @Test func preparedLookAvailabilityUsesTheCachedOwnerAndSurvivesCleanUnpinning() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = CountingPreparedLooks()
        weak var observed: MonitorAssistState<CountingPreparedLooks>?
        var warmHasLUT: Bool?
        let state = MonitorAssistState(
            looks: looks, storage: defaults,
            keys: keys, cleanPinCases: allowed,
            onToggle: { tool, enabled in
                guard tool == .falseColor, enabled, let current = observed else { return }
                warmHasLUT = current.lutEnabled && current.hasPreparedLUT
            })
        observed = state
        let preparedReads = looks.resolverCalls
        #expect(preparedReads > 0)
        state.clean = true
        state.cleanViewPinnedTools.remove(.lut)
        #expect(state.lutEnabled && state.effects.lutDimension == 0)
        looks.available = false
        #expect(state.hasPreparedLUT && state.hasPreparedLUT)
        state.toggle(.falseColor)
        #expect(warmHasLUT == true && looks.resolverCalls == preparedReads)
        state.refreshLUTCube()
        #expect(!state.hasPreparedLUT && looks.resolverCalls == preparedReads + 1)
        looks.available = true
        state.refreshLUTCube()
        #expect(state.hasPreparedLUT && state.effects.lutDimension == 0)
        let refreshedReads = looks.resolverCalls
        state.lutEnabled = false
        state.refreshLUTCube()
        #expect(!state.hasPreparedLUT && looks.resolverCalls == refreshedReads)
        state.lutEnabled = true
        state.refreshLUTCube()
        #expect(state.hasPreparedLUT && looks.resolverCalls == refreshedReads + 1)
    }

    @Test func hostLookReadinessDefersNativeResolutionUntilMigratedPreferencesAreRestored() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = ReadinessPreparedLooks()
        let state = MonitorAssistState(
            looks: looks, storage: defaults,
            keys: keys, cleanPinCases: allowed)
        #expect(looks.nativeRequests.isEmpty && !state.hasPreparedLUT)
        // The host restores its saved look/migration and source interpretation before readiness.
        looks.selection = 7
        looks.transfer = .dlogm
        looks.ready = true
        state.refreshLUTCube()
        #expect(
            looks.nativeRequests == [ReadinessPreparedLooks.Request(selection: 7, transfer: .dlogm)]
        )
        #expect(state.hasPreparedLUT && state.effects.transfer == .dlogm)
        _ = state.hasPreparedLUT
        state.clean = true
        state.cleanViewPinnedTools.remove(.lut)
        _ = state.effects
        #expect(looks.nativeRequests.count == 1 && state.hasPreparedLUT)
    }
}

@MainActor final class StateTestLooks: MonitorLookProvider {
    var selection = 0
    var transfer = MonitorTransfer.rec709
    var sourceTransfer: MonitorTransfer? = .rec709
    var bakeTransfer: MonitorTransfer?
    var referenceClipByte = 255
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer {
        bakeTransfer ?? transfer
    }
    var cube: CubeLUT? {
        CubeLUT(
            size: 2,
            rgb: (0..<8).flatMap { index -> [Float] in
                let r = Float(index & 1)
                let g = Float((index >> 1) & 1)
                let b = Float((index >> 2) & 1)
                return selection == 0 ? [r, g, b] : [b, r, g]
            })
    }
}

@MainActor private final class CountingPreparedLooks: MonitorLookProvider {
    var selection = 0
    var transfer = MonitorTransfer.rec709
    var referenceClipByte = 255
    var available = true
    private(set) var resolverCalls = 0
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    var cube: CubeLUT? {
        resolverCalls += 1
        guard available else { return nil }
        return CubeLUT(
            size: 2,
            rgb: (0..<8).flatMap { index -> [Float] in
                let red = Float(index & 1)
                let green = Float((index >> 1) & 1)
                let blue = Float((index >> 2) & 1)
                return [red, green, blue]
            })
    }
}

@MainActor private final class ReadinessPreparedLooks: MonitorLookProvider {
    struct Request: Equatable {
        let selection: Int
        let transfer: MonitorTransfer
    }
    var selection = 0
    var transfer = MonitorTransfer.rec709
    var referenceClipByte = 255
    var ready = false
    private(set) var nativeRequests: [Request] = []
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    var cube: CubeLUT? {
        guard ready else { return nil }
        nativeRequests.append(Request(selection: selection, transfer: transfer))
        return CubeLUT(
            size: 2,
            rgb: (0..<8).flatMap { index -> [Float] in
                let red = Float(index & 1)
                let green = Float((index >> 1) & 1)
                let blue = Float((index >> 2) & 1)
                return [red, green, blue]
            })
    }
}
