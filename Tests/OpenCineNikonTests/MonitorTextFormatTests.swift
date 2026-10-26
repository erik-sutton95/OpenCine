import Testing

@testable import OpenCineNikon

// MARK: - Resolution label

@Test func resolutionLabelDerivesClassFromPixelWidth() {
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 6048, pixelHeight: 3402, frameRate: 23.976)
            == "6K · 24p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 3840, pixelHeight: 2160, frameRate: 25.0)
            == "4K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 7680, pixelHeight: 4320, frameRate: 30)
            == "8K · 30p")
}

@Test func resolutionLabelRoundsFractionalFrameRate() {
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 6048, pixelHeight: 3402, frameRate: 29.97)
            == "6K · 30p")
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 3840, pixelHeight: 2160, frameRate: 59.94)
            == "4K · 60p")
}

@Test func resolutionLabelFallsBackToWidthPixelsForUnknownClass() {
    // Sub-4K widths use the raw horizontal pixel count so the readout stays honest.
    #expect(
        MonitorTextFormat.resolutionLabel(pixelWidth: 1920, pixelHeight: 1080, frameRate: 24)
            == "1920 · 24p")
}

/// A5-12: an unknown frame rate is left out, never shown as `0p`; the Kotlin twin reads the same
/// vectors (`Fixtures/nikon-monitor-text.tsv`).
@Test func resolutionLabelLeavesOutAnUnknownRate() {
    #expect(MonitorTextFormat.resolutionLabel(fromProperty: "3840x2160", frameRate: 0) == "4K")
    #expect(MonitorTextFormat.resolutionLabel(pixelWidth: 6048, pixelHeight: 3402, frameRate: 0) == "6K")
}

// MARK: - Media status

@Test func mediaCapacityLabelCombinesGigabytesAndPercent() {
    let status = MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    #expect(status.capacityLabel == "521 GB · 47%")
}

@Test func mediaDurationLabelUsesMinutes() {
    let status = MediaStatus(gigabytesFree: 521, percentFree: 47, minutesRemaining: 47)
    #expect(status.durationLabel == "~47 Min")
}

// MARK: - Resolution label from camera property string

@Test func resolutionLabelParsesCameraPropertyDimensions() {
    // The PTP property arrives as a raw "WxH" string; the top bar shows the compact class.
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "6048x3402", frameRate: 25) == "6K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "3840x2160", frameRate: 30) == "4K · 30p")
}

@Test func resolutionLabelFallsBackWhenPropertyUnparsable() {
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: nil, frameRate: 25, fallback: "6K · 25p")
            == "6K · 25p")
    #expect(
        MonitorTextFormat.resolutionLabel(fromProperty: "unexpected", frameRate: 25, fallback: "6K")
            == "6K")
}

// MARK: - Codec short label

@Test func codecShortLabelCollapsesRedundantSuffix() {
    // Camera reports "R3D NE 10-bit R3D"; the top bar shows the short family name.
    #expect(MonitorTextFormat.codecShortLabel("R3D NE 10-bit R3D") == "R3D NE")
    #expect(MonitorTextFormat.codecShortLabel("N-RAW 12-bit N-RAW") == "N-RAW")
}

@Test func codecShortLabelKeepsAlreadyShortNames() {
    #expect(MonitorTextFormat.codecShortLabel("ProRes RAW HQ") == "ProRes RAW HQ")
    #expect(MonitorTextFormat.codecShortLabel("R3D NE") == "R3D NE")
}

@Test func codecCompactLabelAbbreviatesFamiliesForTightReadouts() {
    #expect(MonitorTextFormat.codecCompactLabel("ProRes RAW HQ") == "PR RAW HQ")
    #expect(MonitorTextFormat.codecCompactLabel("ProRes 422 HQ") == "PR 422 HQ")
    #expect(MonitorTextFormat.codecCompactLabel("H.265 10-bit") == "H.265")
    #expect(MonitorTextFormat.codecCompactLabel("R3D NE") == "R3D NE")
    #expect(MonitorTextFormat.codecCompactLabel("N-RAW") == "N-RAW")
}

@Test func isRawCodecClassifiesRawFamilies() {
    #expect(MonitorTextFormat.isRawCodec("R3D NE"))
    #expect(MonitorTextFormat.isRawCodec("R3D NE 10-bit R3D"))
    #expect(MonitorTextFormat.isRawCodec("N-RAW"))
    #expect(MonitorTextFormat.isRawCodec("ProRes RAW HQ"))
    #expect(!MonitorTextFormat.isRawCodec("ProRes 422 HQ"))
    #expect(!MonitorTextFormat.isRawCodec("H.265"))
    #expect(!MonitorTextFormat.isRawCodec("H.264"))
    #expect(!MonitorTextFormat.isRawCodec(""))
}

// MARK: - Codec label cost (lane media-perf, 2026-10-25)

/// The live surface formats the codec readout on every evaluation, and a running timecode
/// re-evaluates it once per live view frame. Build 304's CPU report and a simulator profile both
/// showed `codecShortLabel` building and running a Regex per call on the main thread.
@Test func codecLabelsMatchTheRegexDefinitionOnEdgeVectors() {
    let vectors: [(String, String, String)] = [
        ("R3D NE 10-bit R3D", "R3D NE", "R3D NE"),
        ("N-RAW 12-bit N-RAW", "N-RAW", "N-RAW"),
        ("  H.265 10-bit  ", "H.265 10-bit", "H.265"),
        ("H.264 8-bit", "H.264 8-bit", "H.264"),
        ("H.265 10-bit 4:2:2", "H.265", "H.265"),
        ("ProRes 422 HQ 10-bit ProRes", "ProRes 422 HQ", "PR 422 HQ"),
        ("10-bit R3D", "10-bit R3D", "10-bit R3D"),
        ("X 10-bitR3D", "X 10-bitR3D", "X 10-bitR3D"),
        ("X -bit Y", "X -bit Y", "X -bit Y"),
        ("A 1-bit B 2-bit C", "A", "A"),
        ("A\t12-bit\tB", "A", "A"),
        ("A 12-bit ", "A 12-bit", "A 12-bit"),
        ("", "", ""),
    ]
    for (raw, short, compact) in vectors {
        #expect(MonitorTextFormat.codecShortLabel(raw) == short, "\(raw)")
        #expect(MonitorTextFormat.codecCompactLabel(raw) == compact, "\(raw)")
    }
}

@Test func codecLabelsStayCheapEnoughForPerFrameEvaluation() {
    let inputs = ["R3D NE 10-bit R3D", "ProRes RAW HQ", "H.265 10-bit", "N-RAW 12-bit N-RAW"]
    let clock = ContinuousClock()
    var characters = 0
    func labels() {
        for index in 0..<20_000 {
            let raw = inputs[index % inputs.count]
            characters += MonitorTextFormat.codecShortLabel(raw).count
            characters += MonitorTextFormat.codecCompactLabel(raw).count
        }
    }
    func reference() {
        for index in 0..<40_000 { characters += inputs[index % inputs.count].uppercased().count }
    }
    // Interleaved passes, cheapest of each: the hosted runner shares its cores with the parallel
    // suite (PR #276 saw one pass take 244 ms), and contention slows both loops alike.
    var label = Duration.seconds(1_000), base = Duration.seconds(1_000)
    for _ in 0..<5 {
        label = min(label, clock.measure(labels))
        base = min(base, clock.measure(reference))
    }
    #expect(characters > 0)
    print("PERF codec-labels labels=\(label) uppercased=\(base)")
    // 40,000 labels; a per-call Regex took seconds here (hundreds of times an uppercased copy),
    // plain scanning costs about a dozen.
    #expect(
        label < base * 40 + .milliseconds(5),
        "40,000 codec labels took \(label), 40,000 uppercased \(base)")
}
