#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Local optical correction, following the same factor range as the reference monitor.
    public enum DesqueezeAssist {
        public static let factorRange = MonitorAnamorphicDesqueeze.factorRange
        public static let factorStep = MonitorAnamorphicDesqueeze.factorStep
        public static let help =
            "Match your anamorphic lens or adapter. Horizontal widens the picture; Vertical "
            + "corrects a rotated adapter. The full picture fits on screen. Recordings, exports "
            + "and scope measurements stay unchanged."

        public static func snap(_ value: Double) -> Double {
            MonitorAnamorphicDesqueeze.snap(value)
        }

        public static func presentationRect(
            sourceSize: CGSize, in container: CGRect, effects: MonitorFrameEffects
        ) -> CGRect {
            let factor = snap(effects.desqueezeFactor)
            let corrected = CGSize(
                width: sourceSize.width * (effects.desqueezeHorizontal ? factor : 1),
                height: sourceSize.height * (effects.desqueezeHorizontal ? 1 : factor))
            return PlaybackVideoLayout.aspectFitRect(videoSize: corrected, in: container)
        }

        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) -> some View {
            DesqueezeLongPressMenu(assist: assist, haptics: haptics)
        }
    }

    extension MonitorAssistState {
        public func selectDesqueezePreset(_ preset: MonitorDesqueezePreset) {
            desqueezeCustom = false
            desqueezeFactor = preset.factor
            persist()
        }

        public func selectDesqueezeCustom() {
            desqueezeCustom = true
            desqueezeFactor = DesqueezeAssist.snap(desqueezeCustomFactor)
            persist()
        }

        public func updateDesqueezeCustom(_ value: Double) {
            desqueezeCustom = true
            desqueezeCustomFactor = DesqueezeAssist.snap(value)
            desqueezeFactor = desqueezeCustomFactor
        }
    }

    public struct DesqueezeLongPressMenu<Looks: MonitorLookProvider>: View {
        @Bindable public var assist: MonitorAssistState<Looks>
        public var haptics: OperatorHaptics

        public init(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) {
            _assist = Bindable(wrappedValue: assist)
            self.haptics = haptics
        }
        public var body: some View {
            MonitorDesqueezeMenu(
                selected: assist.desqueezeCustom
                    ? nil : MonitorDesqueezePreset.matching(assist.desqueezeFactor),
                custom: assist.desqueezeCustom,
                factor: Binding(
                    get: { assist.desqueezeFactor },
                    set: {
                        assist.updateDesqueezeCustom($0)
                    }),
                horizontal: Binding(
                    get: { assist.desqueezeHorizontal },
                    set: {
                        assist.desqueezeHorizontal = $0
                        assist.persist()
                    }), help: DesqueezeAssist.help,
                selectionFeedback: {
                    haptics.selection()
                },
                onSelect: {
                    if let preset = $0 {
                        assist.selectDesqueezePreset(preset)
                    } else {
                        assist.selectDesqueezeCustom()
                    }
                }, onFinish: { assist.persist() })
        }
    }
#endif
