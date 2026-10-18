import Foundation
import Testing

/// Every live entry is the one surface. The camera-vocabulary source is a convenience init
/// on it and the descriptor scene calls it; neither keeps a region recipe or a second entry.
struct SingleSharedMonitorCompositionContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let directory = "Sources/OpenCineCameraControls/LiveChrome/"
    private static let surface = "MonitorOperatorLiveSurface.swift"
    private static let regions: Set<String> = [
        "MonitorScreen", "MonitorStatusChrome", "MonitorSystemControls", "MonitorAssistPalette",
        "MonitorOperatorAssistInspector", "MonitorOperatorCaptureStrip", "MonitorOperatorCapturePopup",
    ]

    @Test func everyLiveEntryIsTheOneSurfaceWithoutASecondRegionRecipe() throws {
        let vocabulary = try Self.read(Self.directory + "MonitorOperatorVocabularySurface.swift")
        #expect(Self.delegatesThroughConvenienceInit(vocabulary), "The vocabulary source must extend the one surface")
        #expect(Set(Self.calls(in: vocabulary)).isDisjoint(with: Self.regions), "The vocabulary source retains region composition")
        let scene = try Self.read(Self.directory + "MonitorOperatorScene.swift")
        #expect(Self.calls(in: scene).contains("MonitorOperatorLiveSurface"), "The scene does not enter the one surface")
        #expect(Set(Self.calls(in: scene)).isDisjoint(with: Self.regions), "The scene retains region composition")
    }

    /// A5-14: no app declares the single-camera clock slot. It follows the DISP section in every
    /// app; the source's declared precision decides what it shows (Nano: the seconds placeholder).
    @Test func noAppDeclaresTheClockSlot() throws {
        for file in ["LiveChromeHost.swift", "LiveStatusChrome.swift", "MonitorOperatorVocabularySurface.swift"] {
            #expect(!Self.tokens(in: try Self.read(Self.directory + file)).contains("timecodeAvailable"),
                "\(file) gates the clock on an app flag")
        }
    }

    /// A5-08: `MonitorLayoutCapabilities` is the one layout type; no presentation twin survives.
    @Test func oneLayoutCapabilityType() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.root.appending(path: "Sources/MonitorPresentation"), includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("struct MonitorCapabilities"), "\(file.lastPathComponent) keeps a layout twin")
        }
    }

    @Test func theSurfaceOwnsStatusRailAssistsInspectorAndPopupOnce() throws {
        let source = try Self.read(Self.directory + Self.surface)
        let calls = Self.calls(in: source)
        for region in Self.regions {
            #expect(calls.filter { $0 == region }.count == 1, "Common \(region) must have one composition site")
        }
        let identifiers = Self.tokens(in: source)
        #expect(identifiers.contains("ChromeEditHost"))
        #expect(!identifiers.contains("CaptureSheetHost"))
        #expect(!identifiers.contains("CameraStatus"), "The surface must consume neutral observed facts")
    }

    @Test func theCompositionBehindTheSurfaceIsNotASecondEntry() throws {
        let tokens = Self.tokens(in: try Self.read(Self.directory + Self.surface))
        let declaration = tokens.indices.first { index in
            index + 1 < tokens.count && tokens[index] == "struct" && tokens[index + 1] == "MonitorOperatorLiveBody"
        }
        let index = try #require(declaration)
        #expect(index == 0 || tokens[index - 1] != "public", "The composition must stay internal")
    }

    @Test func generatedAppsStillEnterTheSharedSceneAdapter() throws {
        let source = try Self.read("atlas/templates/app/ios/__NAME__/App.swift.tmpl")
        #expect(Self.calls(in: source).contains("MonitorOperatorScene"))
    }

    @Test func compositionScannerRejectsASecondRecipeAndIgnoresCopyInComments() {
        let source = """
            // MonitorScreen(control: old)
            let example = "MonitorOperatorLiveSurface(host: camera)"
            func MonitorSystemControls() {}
            struct OtherScreen {
                var body: some View { MonitorStatusChrome(layout: layout); MonitorSystemControls() }
            }
            """
        #expect(Self.calls(in: source) == ["MonitorStatusChrome", "MonitorSystemControls"])
        #expect(!Self.calls(in: source).contains("MonitorOperatorLiveSurface"))
    }

    @Test func convenienceInitScannerNeedsTheSurfaceExtensionAndASelfInit() {
        #expect(Self.delegatesThroughConvenienceInit("extension MonitorOperatorLiveSurface where Key == K { init() { self.init(a: 1) } }"))
        #expect(!Self.delegatesThroughConvenienceInit("extension OtherSurface { init() { self.init(a: 1) } }"))
        #expect(!Self.delegatesThroughConvenienceInit("// extension MonitorOperatorLiveSurface { self.init() }"))
        #expect(!Self.delegatesThroughConvenienceInit("extension MonitorOperatorLiveSurface { func make() {} }"))
    }

    private static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    /// A small lexical scan identifies architecture calls and direct aliases;
    /// comments and display strings cannot stand in for an exercised delegation.
    private static func tokens(in source: String) -> [String] {
        let pattern = #"(?:"{3}[\s\S]*?"{3}|/\*[\s\S]*?\*/|//[^\r\n]*|"(?:\\.|[^"\\])*"|([A-Za-z_][A-Za-z_0-9]*)|([()<>=]))"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            for index in [1, 2] {
                if let range = Range(match.range(at: index), in: source) { return String(source[range]) }
            }
            return nil
        }
    }

    private static func delegatesThroughConvenienceInit(_ source: String) -> Bool {
        let tokens = tokens(in: source)
        let extends = tokens.indices.contains { index in
            index + 1 < tokens.count && tokens[index] == "extension" && tokens[index + 1] == "MonitorOperatorLiveSurface"
        }
        let delegates = tokens.indices.contains { index in
            index + 2 < tokens.count && tokens[index] == "self" && tokens[index + 1] == "init" && tokens[index + 2] == "("
        }
        return extends && delegates
    }

    private static func calls(in source: String) -> [String] {
        let tokens = tokens(in: source)
        return tokens.indices.compactMap { index in
            guard index + 1 < tokens.count, tokens[index].hasPrefix("Monitor"),
                index == 0 || !["func", "struct", "class", "enum", "extension"].contains(tokens[index - 1])
            else { return nil }
            var next = index + 1
            if tokens[next] == "<" {
                var depth = 0
                repeat {
                    if tokens[next] == "<" { depth += 1 }
                    if tokens[next] == ">" { depth -= 1 }
                    next += 1
                } while next < tokens.count && depth > 0
            }
            return next < tokens.count && tokens[next] == "(" ? tokens[index] : nil
        }
    }
}
