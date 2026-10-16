#if os(watchOS)
import SwiftUI
import UIKit
import WatchKit

/// One wrist layout and inspection lifetime over typed reports and a retained native preview image.
public struct WatchOperatorScreen: View {
    private let value: WatchMonitorPresentation
    private let image: UIImage?
    private let action: (WatchMonitorAction) -> Void
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @State private var inspection = WatchPreviewInspection()
    @State private var feedSize: CGSize = .zero
    @GestureState private var panPointer = false

    public init(value: WatchMonitorPresentation, image: UIImage?, action: @escaping (WatchMonitorAction) -> Void) {
        self.value = value; self.image = image; self.action = action
    }

    private var isRecording: Bool { value.recording == true }
    private var interactive: Bool { scenePhase == .active && !isLuminanceReduced }

    public var body: some View {
        VStack(spacing: 2) {
            Text(value.header)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(isRecording && value.photography != true ? .red : .primary)
                .frame(maxWidth: .infinity).padding(.horizontal, 6)
                .accessibilityLabel(value.headerAccessibility ?? value.header)
            feed.frame(maxHeight: .infinity)
            bottomBar.padding(.horizontal, 10).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .onChange(of: value.recording) { old, next in
            guard interactive, let next, (old ?? false) != next else { return }
            WKInterfaceDevice.current().play(next ? .success : .failure)
        }
        .onChange(of: value.commandMessage) { _, message in
            if interactive, message != nil { WKInterfaceDevice.current().play(.failure) }
        }
        .onChange(of: value.sourceRevision, initial: true) { _, revision in
            inspection.synchronize(sourceRevision: revision)
            inspection.interruptPan(pointerActive: panPointer)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { inspection.interruptPan(pointerActive: panPointer) }
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            if reduced { inspection.interruptPan(pointerActive: panPointer) }
        }
        .onChange(of: panPointer) { _, active in if !active { inspection.endPointer() } }
        .onDisappear { inspection.interruptPan(pointerActive: panPointer) }
    }

    private var feed: some View {
        Color.black.aspectRatio(value.aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { proxy in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(isLuminanceReduced ? 1 : inspection.zoom)
                            .offset(isLuminanceReduced ? .zero : clampedPan(in: proxy.size))
                            .onAppear { feedSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in
                                inspection.interruptPan(pointerActive: panPointer); feedSize = size
                            }
                    }
                }
            }
            .clipped()
            .overlay {
                if let copy = value.placeholder {
                    Text(copy).font(.caption2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                        .foregroundStyle(.white).padding(6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
                if isRecording { Rectangle().strokeBorder(.red, lineWidth: 3) }
            }
            .overlay(alignment: .bottom) {
                if let message = value.commandMessage {
                    Text(message).font(.system(size: 9, weight: .medium))
                        .minimumScaleFactor(0.7).lineLimit(2).multilineTextAlignment(.center)
                        .foregroundStyle(Color(red: 0.90, green: 0.71, blue: 0.40))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, 6).padding(.bottom, 3)
                }
            }
            .frame(maxWidth: .infinity).focusable()
            .digitalCrownRotation(Binding(get: { inspection.zoom }, set: {
                if interactive { inspection.setZoom($0) }
            }), from: 1, through: WatchPreviewInspection.maximumZoom, by: 0.05,
                sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: !isLuminanceReduced)
            .gesture(DragGesture().updating($panPointer) { _, active, _ in active = true }
                .onChanged { drag in
                    guard interactive else { return }
                    inspection.updatePan(x: drag.translation.width, y: drag.translation.height)
                }.onEnded { _ in
                    guard interactive else { inspection.interruptPan(); inspection.endPointer(); return }
                    inspection.endPan(width: feedSize.width, height: feedSize.height)
                })
    }

    private func clampedPan(in size: CGSize) -> CGSize {
        let pan = inspection.clampedPan(width: size.width, height: size.height)
        return CGSize(width: pan.x, height: pan.y)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Text(value.media ?? "\u{2014}").frame(maxWidth: .infinity, alignment: .leading)
            captureControl
            HStack(spacing: 3) {
                if value.battery != nil { Image(systemName: "camera"); batteryGauge }
            }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    @ViewBuilder private var captureControl: some View {
        if value.photography == true {
            Button { send(.capture, feedback: .success) } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 38, height: 38)
                    Circle().fill(.white).frame(width: 28, height: 28)
                }.frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!value.canCapture || value.sourceRevision == nil || !interactive)
                .opacity(value.canCapture ? 1 : 0.4).accessibilityLabel("Shutter")
        } else {
            Button { send(.record(!isRecording), feedback: .click) } label: {
                ZStack {
                    Circle().stroke(isRecording ? .red : .white.opacity(0.6), lineWidth: 3).frame(width: 34, height: 34)
                    RoundedRectangle(cornerRadius: isRecording ? 3 : 11).fill(.red)
                        .frame(width: isRecording ? 14 : 22, height: isRecording ? 14 : 22)
                }.frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(!value.canCapture || value.sourceRevision == nil || value.photography == nil || value.recording == nil || !interactive)
                .opacity(value.canCapture ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.15), value: isRecording)
                .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        }
    }

    private func send(_ intent: WatchMonitorAction.Intent, feedback: WKHapticType) {
        let command = WatchMonitorAction(sourceRevision: value.sourceRevision, intent: intent)
        guard interactive, value.admits(command) else { return }
        WKInterfaceDevice.current().play(feedback); action(command)
    }

    private var batteryTint: Color {
        switch value.battery?.urgency {
        case .nominal: Color(red: 0.42, green: 0.80, blue: 0.53)
        case .low: .orange
        case .depleted: .red
        case nil: .white.opacity(0.22)
        }
    }

    @ViewBuilder private var batteryGauge: some View {
        if let battery = value.battery {
            TimelineView(.animation(minimumInterval: 0.5,
                paused: battery.exhausted != true || !interactive)) { context in
                Group {
                    switch battery.reading {
                    case .fraction(let value):
                        Text("\(Int((value * 100).rounded()))%")
                    case .steps(let filled, let count):
                        if count > 10 {
                            Text(verbatim: "\(filled)/\(count)")
                                .minimumScaleFactor(0.5)
                        } else {
                            HStack(spacing: 1) {
                                ForEach(0..<count, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                                        .fill(index < filled ? batteryTint : Color.white.opacity(0.22))
                                        .frame(width: 2.5, height: 7)
                                }
                            }
                        }
                    }
                }
                .foregroundStyle(batteryTint)
                .opacity(battery.exhausted == true && interactive
                    && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 0.35 : 1)
                .accessibilityElement().accessibilityLabel(battery.accessibilityLabel)
            }
        }
    }
}
#endif
