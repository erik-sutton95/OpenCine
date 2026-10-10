#if os(iOS)
    import Foundation
    import MonitorPresentation
    import OpenCineAppKit
    import OpenCineMedia

    /// The assist panels' saved presentation: scope options, sizes and places, the audio, ND and
    /// traffic-lights meters, the false-colour reference and the zebra editor's unit. The app
    /// builds one set, under its own key namespace, and hands it to the panels and menus.
    @MainActor
    public final class AssistPanelStores {
        public let waveform: MonitorScopePanelStore<MonitorWaveformOptions>
        public let parade: MonitorScopePanelStore<MonitorParadeOptions>
        public let vectorscope: MonitorScopePanelStore<MonitorVectorscopeOptions>
        public let histogram: MonitorScopePanelStore<MonitorHistogramOptions>
        public let audio: MonitorAudioPreferenceStore
        public let reference: MonitorFalseColorReferencePositionStore
        public let nd: MonitorNDPreferenceStore
        public let trafficLights: MonitorTrafficLightsPreferenceStore
        /// `<namespace>.zebraUnit`: editor-only, saved beside the assist snapshot.
        public let zebraUnitKey: String
        private let storage: UserDefaults

        /// The zebra editor's unit; thresholds themselves stay on the 0-100 monitoring axis.
        public var zebraUnit: ZebraAssist.Unit {
            get { ZebraAssist.Unit(rawValue: storage.string(forKey: zebraUnitKey) ?? "") ?? .ire }
            set { storage.set(newValue.rawValue, forKey: zebraUnitKey) }
        }

        /// Keys are `<namespace>.WaveformAssist.v1`, `<namespace>.Assist.audio.v1` and so on.
        public init(storage: UserDefaults, namespace: String) {
            precondition(!namespace.isEmpty)
            self.storage = storage
            zebraUnitKey = "\(namespace).zebraUnit"
            waveform = MonitorScopePanelStore(
                storage: storage, key: "\(namespace).WaveformAssist.v1")
            parade = MonitorScopePanelStore(storage: storage, key: "\(namespace).ParadeAssist.v1")
            vectorscope = MonitorScopePanelStore(
                storage: storage, key: "\(namespace).VectorscopeAssist.v1")
            histogram = MonitorScopePanelStore(
                storage: storage, key: "\(namespace).HistogramAssist.v1")
            audio = MonitorAudioPreferenceStore(
                storage: storage, key: "\(namespace).Assist.audio.v1")
            reference = MonitorFalseColorReferencePositionStore(
                storage: storage, key: "\(namespace).Assist.falseColorReference.positions.v1")
            nd = MonitorNDPreferenceStore(storage: storage, key: "\(namespace).Assist.ndMeter.v1")
            trafficLights = MonitorTrafficLightsPreferenceStore(
                storage: storage, key: "\(namespace).Assist.trafficLights.v1", histogram: histogram)
        }

        /// Borrow the application's already-restored stores and exact deployed keys.
        public init(storage: UserDefaults, zebraUnitKey: String,
            waveform: MonitorScopePanelStore<MonitorWaveformOptions>,
            parade: MonitorScopePanelStore<MonitorParadeOptions>,
            vectorscope: MonitorScopePanelStore<MonitorVectorscopeOptions>,
            histogram: MonitorScopePanelStore<MonitorHistogramOptions>,
            audio: MonitorAudioPreferenceStore, reference: MonitorFalseColorReferencePositionStore,
            nd: MonitorNDPreferenceStore, trafficLights: MonitorTrafficLightsPreferenceStore) {
            precondition(!zebraUnitKey.isEmpty)
            self.storage = storage; self.zebraUnitKey = zebraUnitKey
            self.waveform = waveform; self.parade = parade; self.vectorscope = vectorscope
            self.histogram = histogram; self.audio = audio; self.reference = reference
            self.nd = nd; self.trafficLights = trafficLights
        }
    }
#endif
