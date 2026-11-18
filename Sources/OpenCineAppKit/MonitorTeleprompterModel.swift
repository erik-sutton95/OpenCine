import Foundation
import MonitorPresentation
import Observation

/// One saved script and its transient reader/import state, retained independently of a camera.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorTeleprompterModel {
    /// The script accepted by the operator, available offline.
    public private(set) var script: TeleprompterScript?
    /// The candidate remains separate until the operator chooses Use script.
    public private(set) var candidate: TeleprompterScript?
    /// Whether a cancellable import is running.
    public private(set) var loading = false
    /// The last import failure, without replacing the saved script.
    public private(set) var error: String?
    /// Requests the shared editor from an empty palette tile or its inspector.
    public var editorRequested = false
    /// Font size in logical display points.
    public var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "teleprompter.fontSize") }
    }
    /// Scroll speed in logical display points per second.
    public var speed: Double { didSet { defaults.set(speed, forKey: "teleprompter.speed") } }
    /// Mirrors text for a reflecting prompter; controls remain readable.
    public var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "teleprompter.mirrored") } }
    /// The black reading plate's opacity; text stays opaque.
    public var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: "teleprompter.backgroundOpacity") }
    }
    /// Whether the existing live picture stays visible behind the reader.
    public var showsPreview: Bool {
        didSet { defaults.set(showsPreview, forKey: "teleprompter.showsPreview") }
    }
    /// Playback is transient and never starts when a reader becomes visible.
    public var playing = false
    /// The explicit reset revision, separate from per-frame scrolling.
    public private(set) var resetID = 0
    /// Native readers update this without invalidating the whole monitor every frame.
    @ObservationIgnored public var position: Double = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importRevision = 0

    /// Restores this application's local script and earlier prototype preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let text = defaults.string(forKey: "teleprompter.script") ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            script = TeleprompterScript(
                text: text, name: defaults.string(forKey: "teleprompter.name") ?? "Script",
                sourceURL: defaults.string(forKey: "teleprompter.sourceURL").flatMap(
                    URL.init(string:)))
        }
        fontSize = min(
            72, max(24, defaults.object(forKey: "teleprompter.fontSize") as? Double ?? 40))
        speed = min(300, max(10, defaults.object(forKey: "teleprompter.speed") as? Double ?? 36))
        mirrored = defaults.bool(forKey: "teleprompter.mirrored")
        backgroundOpacity = min(
            1, max(0, defaults.object(forKey: "teleprompter.backgroundOpacity") as? Double ?? 0.4))
        showsPreview = defaults.object(forKey: "teleprompter.showsPreview") as? Bool ?? true
    }

    /// Opens the editor without changing camera or assist state.
    public func requestEditor() {
        pause()
        editorRequested = true
    }
    /// Pauses and retains the current reading position.
    public func pause() { playing = false }
    /// Pauses and returns to the beginning.
    public func reset() {
        pause()
        position = 0
        resetID += 1
    }

    /// Validates an explicit paste and presents it for review.
    public func previewPaste(_ text: String) {
        cancelImport()
        pause()
        do { candidate = try TeleprompterScriptImport.paste(text) } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads a candidate with cancellation and latest-request ownership.
    @discardableResult
    public func load(using operation: @escaping @Sendable () async throws -> TeleprompterScript)
        -> Task<Void, Never>
    {
        cancelImport()
        pause()
        loading = true
        let revision = importRevision
        let task = Task { [weak self] in
            do {
                let value = try await operation()
                try Task.checkCancellation()
                guard let self, self.importRevision == revision else { return }
                self.candidate = value
                self.loading = false
                self.importTask = nil
            } catch {
                guard let self, self.importRevision == revision else { return }
                self.loading = false
                self.importTask = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
        importTask = task
        return task
    }

    /// Cancels pending work and discards its preview while preserving the accepted script.
    public func cancelImport() {
        importRevision += 1
        importTask?.cancel()
        importTask = nil
        loading = false
        candidate = nil
        error = nil
    }

    /// Explicitly accepts the preview, saves it offline and resets only the reader.
    public func useCandidate() {
        guard let candidate else { return }
        script = candidate
        self.candidate = nil
        reset()
        saveScript()
    }

    /// Validates a correction before saving; a rejected draft leaves the accepted script intact.
    @discardableResult
    public func updateText(_ text: String) -> Bool {
        pause()
        do {
            let validated = try TeleprompterScriptImport.paste(text)
            script = TeleprompterScript(
                text: validated.text, name: script?.name ?? "Script", sourceURL: script?.sourceURL)
            error = nil
            saveScript()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func saveScript() {
        defaults.set(script?.text ?? "", forKey: "teleprompter.script")
        defaults.set(script?.name, forKey: "teleprompter.name")
        defaults.set(script?.sourceURL?.absoluteString, forKey: "teleprompter.sourceURL")
    }
}
