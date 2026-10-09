import Foundation
import Testing

/// The three exercised live entries are adapters to one composition owner.
/// This protects a new app using Scene as well as the two existing host APIs.
struct SingleSharedMonitorCompositionContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let directory = "Sources/OpenCineCameraControls/LiveChrome/"
    private static let adapters = [
        "MonitorOperatorLiveSurface.swift", "MonitorOperatorDescriptorLiveSurface.swift",
        "MonitorOperatorScene.swift",
    ]
    private static let regions: Set<String> = [
        "MonitorScreen", "MonitorStatusChrome", "MonitorSystemControls", "MonitorAssistPalette",
        "MonitorOperatorAssistInspector", "MonitorOperatorCaptureStrip", "MonitorOperatorCapturePopup",
    ]

    @Test func everyLiveEntryDelegatesWithoutKeepingASecondRegionRecipe() throws {
        for name in Self.adapters {
            let source = try Self.read(Self.directory + name)
            let calls = Self.calls(in: source)
            let entry = name.replacingOccurrences(of: ".swift", with: "")
            #expect(calls.contains("MonitorOperatorLiveBody") || Self.directBodyAlias(in: source, named: entry),
                "\(name) does not enter the common body")
            #expect(Set(calls).isDisjoint(with: Self.regions), "\(name) retains common region composition")
        }
    }

    @Test func commonBodyOwnsStatusRailAssistsInspectorAndPopupOnce() throws {
        let source = try Self.read(Self.directory + "MonitorOperatorLiveBody.swift")
        let calls = Self.calls(in: source)
        for region in Self.regions {
            #expect(calls.filter { $0 == region }.count == 1, "Common \(region) must have one composition site")
        }
        let identifiers = Set(Self.tokens(in: source))
        #expect(identifiers.contains("ChromeEditHost"))
        #expect(!identifiers.contains("CaptureSheetHost"))
        #expect(!identifiers.contains("CameraStatus"), "The common body must consume neutral observed facts")
    }

    @Test func generatedAppsStillEnterTheSharedSceneAdapter() throws {
        let source = try Self.read("atlas/templates/app/ios/__NAME__/App.swift.tmpl")
        #expect(Self.calls(in: source).contains("MonitorOperatorScene"))
    }

    @Test func compositionScannerRejectsASecondRecipeAndIgnoresCopyInComments() {
        let source = """
            // MonitorScreen(control: old)
            let example = "MonitorOperatorLiveBody(host: camera)"
            func MonitorSystemControls() {}
            struct OtherScreen {
                var body: some View { MonitorStatusChrome(layout: layout); MonitorSystemControls() }
            }
            """
        #expect(Self.calls(in: source) == ["MonitorStatusChrome", "MonitorSystemControls"])
        #expect(!Self.calls(in: source).contains("MonitorOperatorLiveBody"))
    }

    @Test func compositionScannerRecognizesOnlyTheEntryDirectPublicAlias() {
        let entry = "MonitorOperatorDescriptorLiveSurface"
        let direct = """
            public typealias MonitorOperatorDescriptorLiveSurface<Host: ChromeEditHost, Key: Hashable>
                = MonitorOperatorLiveBody<Host, Key, Never, Dictionary<String, Array<Int>>>
            """
        #expect(Self.directBodyAlias(in: direct, named: entry))
        let rejected = [
            "// public typealias MonitorOperatorDescriptorLiveSurface<T> = MonitorOperatorLiveBody<T>",
            "let example = \"public typealias MonitorOperatorDescriptorLiveSurface<T> = MonitorOperatorLiveBody<T>\"",
            "public typealias OtherEntry<T> = MonitorOperatorLiveBody<T>",
            "typealias MonitorOperatorDescriptorLiveSurface<T> = MonitorOperatorLiveBody<T>",
            "public typealias MonitorOperatorDescriptorLiveSurface<T> = OtherEntry<T>; public typealias OtherEntry<T> = MonitorOperatorLiveBody<T>",
            "public typealias MonitorOperatorDescriptorLiveSurface<T = MonitorOperatorLiveBody<T>",
            "public typealias MonitorOperatorDescriptorLiveSurface<T> = MonitorOperatorLiveBody<Array<T>",
        ]
        for source in rejected {
            #expect(!Self.directBodyAlias(in: source, named: entry))
        }
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

    private static func directBodyAlias(in source: String, named entry: String) -> Bool {
        let tokens = tokens(in: source)
        for index in tokens.indices {
            guard index + 2 < tokens.count,
                Array(tokens[index...(index + 2)]) == ["public", "typealias", entry]
            else { continue }
            var next = index + 3
            if next < tokens.count, tokens[next] == "<" {
                guard let end = genericEnd(in: tokens, startingAt: next) else { continue }
                next = end
            }
            guard next + 2 < tokens.count, tokens[next] == "=",
                tokens[next + 1] == "MonitorOperatorLiveBody", tokens[next + 2] == "<",
                genericEnd(in: tokens, startingAt: next + 2) != nil
            else { continue }
            return true
        }
        return false
    }

    private static func genericEnd(in tokens: [String], startingAt start: Int) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index] == "<" { depth += 1 }
            if tokens[index] == ">" { depth -= 1 }
            if depth == 0 { return index + 1 }
        }
        return nil
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
