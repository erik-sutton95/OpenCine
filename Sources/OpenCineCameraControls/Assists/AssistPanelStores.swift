#if os(iOS)
    import Foundation
    import MonitorPresentation
    import OpenCineAppKit
    import OpenCineMedia

    /// The assist panels' saved presentation: scope options, sizes and places, the audio, ND and
    /// traffic-lights meters, and the false-colour reference. The app builds one set, under its
    /// own key namespace, and hands it to the panels and menus.
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

        /// Keys are `<namespace>.WaveformAssist.v1`, `<namespace>.Assist.audio.v1` and so on.
        public init(storage: UserDefaults, namespace: String) {
            precondition(!namespace.isEmpty)
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
    }
#endif
