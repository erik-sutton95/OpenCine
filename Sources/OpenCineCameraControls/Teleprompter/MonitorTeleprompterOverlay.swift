#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import SwiftUI

    struct MonitorTeleprompterOverlay: View {
        @Bindable var model: MonitorTeleprompterModel
        let layout: FieldMonitorLayout
        let safeArea: MonitorSafeArea
        let shown: MonitorScopeChrome
        let motionCluster: Bool
        let extraObstacles: @MainActor () -> [MonitorRect]
        let interactive: Bool
        let onSettings: () -> Void

        var body: some View {
            if let script = model.script {
                let frame = TeleprompterOverlayLayout.frame(
                    layout: layout, safeArea: safeArea,
                    shown: shown, motionCluster: motionCluster, extraObstacles: extraObstacles())
                if !model.showsPreview {
                    Color.black.frame(width: layout.picture.width, height: layout.picture.height)
                        .position(x: layout.picture.midX, y: layout.picture.midY).allowsHitTesting(
                            false)
                }
                TeleprompterReader(
                    text: script.text, fontSize: model.fontSize, speed: model.speed,
                    mirrored: model.mirrored, backgroundOpacity: model.backgroundOpacity,
                    playing: $model.playing,
                    position: Binding(get: { model.position }, set: { model.position = $0 }),
                    resetID: model.resetID, interactive: interactive, onSettings: onSettings
                )
                .frame(width: frame.width, height: frame.height).position(
                    x: frame.midX, y: frame.midY
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("teleprompter.overlay")
            }
        }
    }

    struct MonitorTeleprompterInspector<Looks: MonitorLookProvider>: View {
        @Bindable var model: MonitorTeleprompterModel
        let assist: MonitorAssistState<Looks>
        let viewport: CGSize
        let safeArea: MonitorSafeArea
        let tools: [MonitorAssistSelection]
        let onDismiss: () -> Void

        private func descriptor(_ tool: MonitorAssistSelection) -> MonitorInspectorTool<
            MonitorAssistSelection
        > {
            MonitorInspectorTool(
                value: tool, title: tool.title, label: tool.rawValue, contentStyle: .fullWidth)
        }
        var body: some View {
            MonitorToolInspector(
                selection: descriptor(.teleprompter),
                tools: tools.filter(\.hasConfiguration).map(descriptor), viewport: viewport,
                safeArea: EdgeInsets(
                    top: safeArea.top, leading: safeArea.leading, bottom: safeArea.bottom,
                    trailing: safeArea.trailing),
                onSelect: { assist.configureTool = $0 }, onDismiss: onDismiss,
                glyph: { selection in
                    if let tool = selection.sharedTool {
                        MonitorAssistToolGlyph(tool: tool, size: 17)
                    }
                },
                content: {
                    MonitorInspectorCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.script?.name ?? "No script loaded").font(
                                MonitorTheme.font(14, weight: .semibold))
                            Button("Add or edit script") {
                                onDismiss()
                                model.requestEditor()
                            }
                            .buttonStyle(.bordered).accessibilityIdentifier("teleprompter.manage")
                            Text("Text \(Int(model.fontSize))")
                            Slider(value: $model.fontSize, in: 24...72, step: 2).accessibilityLabel(
                                "Text size")
                            Text("Speed \(Int(model.speed))")
                            Slider(value: $model.speed, in: 10...300, step: 2).accessibilityLabel(
                                "Scroll speed")
                            Toggle("Mirror text", isOn: $model.mirrored)
                            Toggle("Live preview", isOn: $model.showsPreview)
                            Text("Background \(Int(model.backgroundOpacity * 100))%")
                            Slider(value: $model.backgroundOpacity, in: 0...1, step: 0.05)
                                .accessibilityLabel("Background opacity").accessibilityIdentifier(
                                    "teleprompter.opacity")
                            Toggle(
                                "Keep in clean view",
                                isOn: Binding(
                                    get: { assist.cleanViewPinnedTools.contains(.teleprompter) },
                                    set: { _ in assist.toggleCleanViewPin(.teleprompter) }))
                        }.font(MonitorTheme.font(13))
                    }
                },
                footer: {
                    EmptyView()
                }
            )
            .onAppear { model.pause() }
        }
    }
#endif
