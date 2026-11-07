#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// A bounded reader over an existing picture. Its backing plate never dims the text.
    public struct TeleprompterReader: View {
        private let text: String
        private let fontSize: Double
        private let speed: Double
        private let mirrored: Bool
        private let backgroundOpacity: Double
        private let resetID: Int
        private let interactive: Bool
        private let onSettings: (() -> Void)?
        @Binding private var playing: Bool
        @Binding private var position: Double
        @Environment(\.scenePhase) private var scenePhase
        @State private var localReset = 0

        /// Native scrolling updates only these bindings. `onSettings` opens the host's settings after pausing.
        public init(
            text: String, fontSize: Double, speed: Double, mirrored: Bool,
            backgroundOpacity: Double, playing: Binding<Bool>, position: Binding<Double>,
            resetID: Int, interactive: Bool = true, onSettings: (() -> Void)? = nil
        ) {
            self.text = text
            self.fontSize = fontSize
            self.speed = speed
            self.mirrored = mirrored
            self.backgroundOpacity = backgroundOpacity
            self.resetID = resetID
            self.interactive = interactive
            self.onSettings = onSettings
            _playing = playing
            _position = position
        }

        public var body: some View {
            VStack(spacing: 0) {
                TeleprompterScroll(
                    text: text, fontSize: fontSize, speed: speed, mirrored: mirrored,
                    playing: $playing, position: $position, resetID: resetID + localReset
                )
                .accessibilityIdentifier("teleprompter.script")
                .disabled(!interactive)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    MonitorChromeButton(
                        playing ? "Pause" : "Play", size: CGSize(width: 44, height: 44),
                        action: { playing.toggle() },
                        label: {
                            (playing ? MonitorIcon.pause : MonitorIcon.play).frame(
                                width: 18, height: 18)
                        }
                    )
                    .accessibilityIdentifier("teleprompter.play")
                    MonitorChromeButton(
                        "Reset", size: CGSize(width: 44, height: 44),
                        action: {
                            playing = false
                            position = 0
                            localReset += 1
                        }, label: { MonitorIcon.rotateCw.frame(width: 18, height: 18) }
                    )
                    .accessibilityIdentifier("teleprompter.reset")
                    if let onSettings {
                        MonitorChromeButton(
                            "Teleprompter settings", size: CGSize(width: 44, height: 44),
                            action: {
                                playing = false
                                onSettings()
                            },
                            label: { MonitorIcon.settings.frame(width: 18, height: 18) }
                        )
                        .accessibilityIdentifier("teleprompter.settings")
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .padding(.bottom, 6)
                .disabled(!interactive)
            }
            .background(Color.black.opacity(backgroundOpacity))
            .foregroundStyle(.white).tint(MonitorTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MonitorTheme.radius))
            .allowsHitTesting(interactive)
            .onChange(of: scenePhase) { _, value in if value != .active { playing = false } }
            .onDisappear { playing = false }
        }
    }

    private struct TeleprompterScroll: UIViewRepresentable {
        let text: String
        let fontSize: Double
        let speed: Double
        let mirrored: Bool
        @Binding var playing: Bool
        @Binding var position: Double
        let resetID: Int

        func makeCoordinator() -> Coordinator {
            Coordinator(playing: $playing, position: $position, resetID: resetID)
        }
        func makeUIView(context: Context) -> ScriptScrollView {
            let view = ScriptScrollView()
            view.delegate = context.coordinator
            context.coordinator.view = view
            view.restoredPosition = position
            return view
        }
        func updateUIView(_ view: ScriptScrollView, context: Context) {
            view.isScrollEnabled = context.environment.isEnabled
            if view.script.text != text || view.script.font?.pointSize != CGFloat(fontSize)
                || view.mirrored != mirrored
            {
                view.script.text = text
                view.script.font = .systemFont(ofSize: fontSize, weight: .medium)
                view.mirrored = mirrored
                view.invalidateScriptLayout()
            }
            let coordinator = context.coordinator
            coordinator.playing = $playing
            coordinator.position = $position
            coordinator.speed = speed
            if coordinator.resetID != resetID
                || (!playing && position == 0 && view.contentOffset.y != 0)
            {
                coordinator.resetID = resetID
                coordinator.playback.reset()
                view.setContentOffset(.zero, animated: false)
            }
            coordinator.setPlaying(playing)
        }
        static func dismantleUIView(_ view: ScriptScrollView, coordinator: Coordinator) {
            // The scroll delegate publishes position before the SwiftUI graph is torn down.
            coordinator.setPlaying(false)
            view.delegate = nil
        }

        @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
            var playing: Binding<Bool>
            var position: Binding<Double>
            weak var view: ScriptScrollView?
            var speed = 36.0
            var resetID = 0
            var playback = TeleprompterPlayback()
            private var displayLink: CADisplayLink?
            private var previousTime: TimeInterval?
            init(playing: Binding<Bool>, position: Binding<Double>, resetID: Int) {
                self.playing = playing
                self.position = position
                self.resetID = resetID
            }
            func setPlaying(_ enabled: Bool) {
                if enabled, displayLink == nil {
                    playback.seek(to: Double(view?.contentOffset.y ?? 0))
                    playback.play()
                    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                    link.preferredFrameRateRange = CAFrameRateRange(
                        minimum: 30, maximum: 30, preferred: 30)
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                } else if !enabled {
                    displayLink?.invalidate()
                    displayLink = nil
                    previousTime = nil
                    playback.pause()
                }
            }
            @objc private func tick(_ link: CADisplayLink) {
                guard let view else {
                    setPlaying(false)
                    return
                }
                let elapsed = previousTime.map { link.timestamp - $0 } ?? 0
                previousTime = link.timestamp
                playback.advance(
                    elapsed: elapsed, speed: speed,
                    end: view.contentSize.height - view.bounds.height)
                view.setContentOffset(CGPoint(x: 0, y: playback.position), animated: false)
                position.wrappedValue = playback.position
                if !playback.isPlaying {
                    setPlaying(false)
                    playing.wrappedValue = false
                }
            }
            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                setPlaying(false)
                playing.wrappedValue = false
            }
            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                position.wrappedValue = max(0, Double(scrollView.contentOffset.y))
            }
        }
    }

    private final class ScriptScrollView: UIScrollView {
        let script = UILabel()
        var mirrored = false
        var restoredPosition: Double?
        private var needsScriptLayout = true
        private var viewportSize = CGSize.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            indicatorStyle = .white
            script.numberOfLines = 0
            script.textColor = .white
            addSubview(script)
        }
        required init?(coder: NSCoder) { nil }
        func invalidateScriptLayout() {
            needsScriptLayout = true
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard needsScriptLayout || viewportSize != bounds.size else { return }
            needsScriptLayout = false
            viewportSize = bounds.size
            let width = max(1, bounds.width - 32)
            let height = script.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                .height
            script.transform = .identity
            script.frame = CGRect(x: 16, y: 16, width: width, height: height)
            script.transform = CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1)
            contentSize = CGSize(width: bounds.width, height: height + 32 + bounds.height * 0.6)
            if let restoredPosition {
                self.restoredPosition = nil
                contentOffset.y = min(
                    max(0, contentSize.height - bounds.height), CGFloat(restoredPosition))
            }
        }
    }
#endif
