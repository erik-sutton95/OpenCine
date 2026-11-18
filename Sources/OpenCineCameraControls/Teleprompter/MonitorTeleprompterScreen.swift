#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import SwiftUI
    import UniformTypeIdentifiers

    /// Shared script manager and offline reader. The host retains the camera session beneath it.
    public struct MonitorTeleprompterScreen: View {
        @Bindable private var model: MonitorTeleprompterModel
        private let onClose: () -> Void
        private let onUseScript: (() -> Void)?
        @State private var files = false
        @State private var linkEntry = false
        @State private var link = ""
        @State private var linkError: String?
        @State private var editing = false
        @State private var draftText = ""
        @State private var reading = false
        @Environment(\.monitorWindowGeometry) private var windowGeometry

        /// `onUseScript` reveals a live monitor; absent it, the saved script remains available offline.
        public init(
            model: MonitorTeleprompterModel, onClose: @escaping () -> Void,
            onUseScript: (() -> Void)? = nil
        ) {
            self.model = model
            self.onClose = onClose
            self.onUseScript = onUseScript
        }

        public var body: some View {
            GeometryReader { proxy in
                let safe = MonitorSafeArea(
                    top: max(proxy.safeAreaInsets.top, windowGeometry.safeArea.top),
                    leading: max(proxy.safeAreaInsets.leading, windowGeometry.safeArea.leading),
                    bottom: windowGeometry.validSize == nil
                        ? proxy.safeAreaInsets.bottom : windowGeometry.safeArea.bottom,
                    trailing: max(proxy.safeAreaInsets.trailing, windowGeometry.safeArea.trailing))
                let viewport = MonitorRect(width: proxy.size.width, height: proxy.size.height)
                ZStack(alignment: .topLeading) {
                    if reading, let script = model.script {
                        reader(script)
                            .padding(.leading, safe.leading).padding(.trailing, safe.trailing)
                            .padding(.top, safe.top).padding(.bottom, safe.bottom)
                            .frame(width: viewport.width, height: viewport.height)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("teleprompter.reader")
                    }
                    VStack(spacing: 12) {
                        if !reading {
                            header
                            if let candidate = model.candidate {
                                importPreview(candidate)
                            } else if editing {
                                TextEditor(text: $draftText)
                                    .font(.system(size: 22)).scrollContentBackground(.hidden)
                                    .accessibilityLabel("Script")
                                    .accessibilityIdentifier("teleprompter.script.editor")
                                if let error = model.error {
                                    Text(error).foregroundStyle(MonitorTheme.recording)
                                }
                            } else {
                                managerControls
                            }
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.leading, safe.leading + 20).padding(.trailing, safe.trailing + 20)
                    .padding(.top, safe.top + 12).padding(.bottom, safe.bottom + 12)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(reading ? Color.black : MonitorTheme.background).foregroundStyle(
                    MonitorTheme.text)
            }
            .ignoresSafeArea(.container)
            .tint(MonitorTheme.accent)
            .onAppear { model.pause() }
            .onDisappear {
                model.pause()
                model.cancelImport()
            }
            .fileImporter(
                isPresented: $files,
                allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]
            ) { result in
                switch result {
                case .success(let url): model.load { try await MonitorTeleprompterLoader.file(url) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        model.load { throw error }
                    }
                }
            }
            .sheet(isPresented: $linkEntry) { linkForm.presentationDetents([.medium]) }
        }

        private var header: some View {
            HStack(spacing: 16) {
                Text(editing ? "Edit script" : "Teleprompter").font(
                    MonitorTheme.font(20, weight: .semibold)
                )
                .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if editing {
                    Button("Cancel") {
                        model.cancelImport()
                        editing = false
                    }
                    Button("Done") {
                        if model.updateText(draftText) { editing = false }
                    }.buttonStyle(.borderedProminent).foregroundStyle(MonitorTheme.onAccent)
                } else {
                    if model.script != nil {
                        Button(reading ? "Script" : "Read") {
                            model.pause()
                            reading.toggle()
                            editing = false
                        }.accessibilityIdentifier("teleprompter.read")
                    }
                    Button("Close") {
                        model.pause()
                        model.cancelImport()
                        onClose()
                    }.accessibilityIdentifier("teleprompter.close")
                }
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }

        private func reader(_ script: TeleprompterScript) -> some View {
            TeleprompterReader(
                text: script.text, fontSize: model.fontSize, speed: model.speed,
                mirrored: model.mirrored, backgroundOpacity: 1, playing: $model.playing,
                position: Binding(get: { model.position }, set: { model.position = $0 }),
                resetID: model.resetID,
                onSettings: {
                    model.pause()
                    reading = false
                })
        }

        private var managerControls: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add script").font(MonitorTheme.font(16, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { importButtons }
                        VStack(alignment: .leading, spacing: 12) { importButtons }
                    }.buttonStyle(.bordered)
                    if model.loading {
                        HStack {
                            ProgressView()
                            Text("Loading script")
                            Spacer()
                            Button("Cancel", action: model.cancelImport)
                        }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(MonitorTheme.recording).accessibilityIdentifier(
                            "teleprompter.import.error")
                    }
                    if let script = model.script {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(script.name).font(MonitorTheme.font(16, weight: .semibold))
                                Text(script.sourceURL?.host ?? "Saved on this device").font(
                                    MonitorTheme.font(12)
                                )
                                .foregroundStyle(MonitorTheme.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                model.cancelImport()
                                model.pause()
                                draftText = model.script?.text ?? ""
                                editing = true
                            }
                            .accessibilityIdentifier("teleprompter.edit")
                            if let url = script.sourceURL {
                                Button("Refresh") {
                                    model.load { try await MonitorTeleprompterLoader.remote(url) }
                                }
                                .accessibilityIdentifier("teleprompter.import.refresh")
                            }
                        }.buttonStyle(.bordered)
                    } else {
                        Text(
                            "Paste text, choose a TXT or Markdown file, or import a direct HTTPS text link. Review it before replacing your saved script."
                        )
                        .foregroundStyle(MonitorTheme.secondary)
                    }
                    settings
                }.padding(.bottom, 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teleprompter.manager.controls")
        }

        @ViewBuilder private var importButtons: some View {
            PasteButton(payloadType: String.self) { values in
                if let text = values.first { model.previewPaste(text) }
            }.accessibilityIdentifier("teleprompter.import.paste")
            Button("Import file") {
                model.pause()
                files = true
            }
            .accessibilityIdentifier("teleprompter.import.file")
            Button("Import link") {
                model.pause()
                linkError = nil
                linkEntry = true
            }
            .accessibilityIdentifier("teleprompter.import.link")
        }

        private func importPreview(_ candidate: TeleprompterScript) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview: \(candidate.name)").font(MonitorTheme.font(16, weight: .semibold))
                if model.script != nil {
                    Text("Use script replaces the saved script.").foregroundStyle(
                        MonitorTheme.secondary)
                }
                if candidate.text.count > 4000 {
                    Text(
                        "Preview of the first 4,000 characters. The complete script will be saved."
                    )
                    .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.secondary)
                }
                ScrollView {
                    Text(String(candidate.text.prefix(4000))).font(.system(size: 20)).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("teleprompter.import.preview")
                HStack(spacing: 16) {
                    Button("Cancel", action: model.cancelImport).buttonStyle(.bordered)
                    Spacer()
                    Button("Use script") {
                        model.useCandidate()
                        onUseScript?()
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(MonitorTheme.onAccent)
                    .accessibilityIdentifier(
                        "teleprompter.import.use")
                }.frame(minHeight: 44)
            }
        }

        private var settings: some View {
            VStack(spacing: 12) {
                HStack {
                    Text("Text \(Int(model.fontSize))").frame(width: 76, alignment: .leading)
                    Slider(value: $model.fontSize, in: 24...72, step: 2).accessibilityLabel(
                        "Text size"
                    )
                    .accessibilityIdentifier("teleprompter.fontSize")
                    Text("Speed \(Int(model.speed))").frame(width: 76, alignment: .leading)
                    Slider(value: $model.speed, in: 10...300, step: 2).accessibilityLabel(
                        "Scroll speed"
                    )
                    .accessibilityIdentifier("teleprompter.speed")
                }
                Toggle("Mirror text", isOn: $model.mirrored).accessibilityIdentifier(
                    "teleprompter.mirror")
                Toggle("Live preview", isOn: $model.showsPreview).accessibilityIdentifier(
                    "teleprompter.preview")
                HStack {
                    Text("Background \(Int(model.backgroundOpacity * 100))%")
                    Slider(value: $model.backgroundOpacity, in: 0...1, step: 0.05)
                        .accessibilityLabel("Background opacity")
                        .accessibilityIdentifier("teleprompter.opacity")
                }
            }.font(MonitorTheme.font(13))
        }

        private var linkForm: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use a direct HTTPS link to a TXT or Markdown file.")
                    TextField("https://example.com/script.txt", text: $link).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("teleprompter.import.url")
                    if let linkError { Text(linkError).foregroundStyle(.red) }
                    Button("Preview") {
                        do {
                            let url = try TeleprompterScriptImport.link(link)
                            model.load { try await MonitorTeleprompterLoader.remote(url) }
                            linkEntry = false
                        } catch { linkError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).foregroundStyle(MonitorTheme.onAccent)
                        .accessibilityIdentifier(
                            "teleprompter.import.load")
                    Spacer()
                }.padding(20).navigationTitle("Import link")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { linkEntry = false }
                        }
                    }
            }
            .tint(MonitorTheme.accent)
        }
    }

#endif
