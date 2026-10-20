#if os(iOS)
import OpenCineAppKit
import OpenCineCameraVocabulary
import Testing

@testable import OpenCineCameraControls

/// The shared status-row readout plan: colour folds into the codec readout in portrait and
/// landscape, while a camera without a codec readout keeps its own colour target. Kotlin twin:
/// `MonitorHeaderReadoutPlanTest`.
@Suite struct MonitorHeaderReadoutPlanTests {
    private func readout(_ id: String, _ title: String, _ value: String,
        _ section: MonitorDisplayChrome.Section? = nil) -> MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section> {
        .init(id: id, title: title, value: value, section: section)
    }

    private let format = MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>(
        id: "format", title: "Recording format", value: "6K · 25p")
    private var codec: MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section> {
        readout("codec", "Codec", "R3D NE", .codec)
    }
    private var color: MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section> {
        readout("color", "Color mode", "D-Log2", .color)
    }
    private var modeReadout: MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section> {
        readout("mode", "Shooting mode", "Video")
    }

    private func plan(portrait: Bool, photo: Bool = false,
        format: [MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>]? = nil,
        color: MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>? = nil,
        mode: MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>? = nil,
        accent: MonitorHeaderAccent = .shootingMode,
        mounted: Set<MonitorDisplayChrome.Section> = Set(MonitorDisplayChrome.Section.allCases)
    ) -> MonitorHeaderReadoutPlan<String, MonitorDisplayChrome.Section> {
        MonitorHeaderReadoutPolicy.plan(
            format: format ?? [self.format, codec], color: color ?? self.color,
            mode: mode, accent: accent,
            portrait: portrait, photo: photo, isMounted: { mounted.contains($0) },
            codecSection: .codec)
    }

    @Test func landscapeFoldsColorIntoTheCodecReadout() {
        let landscape = plan(portrait: false)
        #expect(landscape.foldsColor)
        #expect(landscape.color == nil)
        #expect(landscape.combined?.codec.id == "codec")
        #expect(landscape.accessibility(for: codec)?.label == "Codec and color")
        #expect(landscape.accessibility(for: codec)?.value == "R3D NE · D-Log2")
        #expect(landscape.accessibility(for: format) == nil,
            "The format readout is not the combined control")
    }

    @Test func portraitFoldsColorTheSameWay() {
        let portrait = plan(portrait: true)
        #expect(portrait.foldsColor)
        #expect(portrait.color == nil)
        #expect(portrait.accessibility(for: codec) == nil,
            "Portrait keeps its existing spoken codec value")
    }

    @Test func portraitPhotographyKeepsItsExistingStack() {
        let photo = plan(portrait: true, photo: true)
        #expect(!photo.foldsColor)
        #expect(photo.color?.id == "color")
        #expect(photo.accessibility(for: codec) == nil)
    }

    @Test func aCameraWithoutACodecReadoutKeepsItsColorTarget() {
        let colorOnly = plan(portrait: false, format: [format])
        #expect(!colorOnly.foldsColor)
        #expect(colorOnly.color?.id == "color")
        #expect(colorOnly.accessibility(for: color) == nil)
    }

    @Test func anUnmountedCodecDoesNotFoldTheColor() {
        var mounted = Set(MonitorDisplayChrome.Section.allCases)
        mounted.remove(.codec)
        let hidden = plan(portrait: false, mounted: mounted)
        #expect(hidden.format.map(\.id) == ["format"])
        #expect(!hidden.foldsColor)
        #expect(hidden.color?.id == "color")
    }

    @Test func anUnmountedColorIsNotFolded() {
        var mounted = Set(MonitorDisplayChrome.Section.allCases)
        mounted.remove(.color)
        let hidden = plan(portrait: false, mounted: mounted)
        #expect(!hidden.foldsColor)
        #expect(hidden.color == nil)
        #expect(hidden.accessibility(for: codec) == nil)
    }

    @Test func shootingModeAccentStaysOnTheModeReadout() {
        let modeBody = plan(portrait: false, mode: modeReadout)
        #expect(modeBody.accented == "mode")
    }

    @Test func aDeclaredCodecAccentMovesOffTheModeReadout() {
        let codecBody = plan(portrait: false, mode: modeReadout, accent: .codec)
        #expect(codecBody.accented == "codec")
    }

    @Test func aDeclaredCodecAccentWithoutAModeReadoutAccentsTheCodec() {
        // A body with no shooting-mode readout declares the codec.
        let codecBody = plan(portrait: false, accent: .codec)
        #expect(codecBody.accented == "codec")
    }

    @Test func aShootingModeDeclarationNeverMovesTheAccentToTheCodec() {
        // Portrait (and a narrow landscape) draws no mode slot: a shooting-mode body stays
        // unaccented there, as before, instead of borrowing the codec.
        #expect(plan(portrait: true).accented == nil)
        #expect(plan(portrait: false).accented == nil)
    }

    @Test func neitherReadoutLeavesTheHeaderUnaccented() {
        let none = plan(portrait: false, format: [format])
        #expect(none.accented == nil)
    }
}
#endif
