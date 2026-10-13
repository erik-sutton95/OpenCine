#if os(iOS)
    import MonitorPresentation
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import XCTest

    @testable import OpenCineCameraControls

    @MainActor
    final class LUTAssistTests: XCTestCase {
        @MainActor private final class OfficialCalls {
            var sources: [LUTSource] = []
        }

        private static let cube = try! CubeLUT.parse(
            "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")

        private var domains: [String] = []
        private var folders: [URL] = []

        override func tearDown() {
            for domain in domains { UserDefaults().removePersistentDomain(forName: domain) }
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
            super.tearDown()
        }

        private func looks(
            calls: OfficialCalls = OfficialCalls(), preparationReady: Bool = true
        ) -> MonitorLUTLooks {
            let domain = "LUTAssistTests.\(UUID().uuidString)"
            domains.append(domain)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            folders.append(folder)
            let preferences = LUTPreferences(storage: UserDefaults(suiteName: domain)!, namespace: "App")
            return MonitorLUTLooks(
                official: OfficialLUTs(
                    catalog: { _ in [.officialAuto] },
                    cube: { source in
                        calls.sources.append(source)
                        return Self.cube
                    }),
                preferences: preferences,
                customLUTs: CustomLUTStore(root: folder, preferences: preferences),
                preparationReady: preparationReady,
                lookProfile: CameraLUTProfile(automatic: [.dLog: .dji(.pocketDLog),
                    .dLog2: .dji(.pocketDLog2)]))
        }

        private func state(_ looks: MonitorLUTLooks) -> MonitorAssistState<MonitorLUTLooks> {
            let domain = "LUTAssistTests.state.\(UUID().uuidString)"
            domains.append(domain)
            return MonitorAssistState(
                looks: looks, storage: UserDefaults(suiteName: domain)!,
                keys: .init(assist: "A", cleanPins: "C", playback: "P"),
                cleanPinCases: MonitorAssistTool.allCases.map(MonitorAssistSelection.init))
        }

        /// A host that waits for its saved choices gets no cube, and no official lookup, until ready.
        func testPreparationGateWithholdsTheOfficialCube() {
            let calls = OfficialCalls()
            let looks = looks(calls: calls, preparationReady: false)
            looks.monitorColorMode = .dLog2
            XCTAssertNil(looks.cube)
            XCTAssertTrue(calls.sources.isEmpty)

            looks.preparationReady = true
            XCTAssertEqual(looks.cube, Self.cube)
            XCTAssertEqual(calls.sources, [looks.resolvedSource()])
        }

        /// Creative looks and Off never ask the host for an official cube.
        func testCreativeAndOffStayOutOfTheOfficialLookup() {
            let calls = OfficialCalls()
            let looks = looks(calls: calls)
            looks.lutSelection = .creativeMono
            XCTAssertEqual(looks.cube, BuiltInLook.mono.cube())
            looks.lutSelection = .customFile
            XCTAssertNil(looks.cube)
            XCTAssertTrue(calls.sources.isEmpty)
        }

        /// Live Photo is Rec.709: the label says so, and the last live log colour is kept.
        func testLivePhotoKeepsTheLastLiveColour() {
            let assist = state(looks())
            assist.selectLUT(.officialAuto)
            assist.syncLUT(to: .dLog2)
            XCTAssertEqual(assist.looks.preferences.lastMonitorColorMode, .dLog2)

            assist.syncLUT(to: .dLog, isPhoto: true)
            XCTAssertTrue(assist.liveIsPhoto)
            XCTAssertEqual(assist.monitorColorMode, .normal)
            XCTAssertEqual(assist.lutStatusLabel, "Auto · Rec.709")
            XCTAssertEqual(assist.looks.preferences.lastMonitorColorMode, .dLog2)
        }

        /// Import arms the file unless an Auto row is selected; clearing it returns to Auto.
        func testCustomFileImportArmsAndClears() {
            let assist = state(looks())
            let preferences = assist.looks.preferences
            assist.importCustom(fileName: "a.cube")
            XCTAssertEqual(assist.lutSelection, .officialAuto)
            XCTAssertTrue(assist.lutEnabled)
            XCTAssertEqual(preferences.selectedCustomFileName, "a.cube")

            assist.selectLUT(.creativeWarm)
            XCTAssertEqual(preferences.lutSelection, .creativeWarm)
            assist.importCustom(slot: .dLog, fileName: "b.cube")
            XCTAssertEqual(assist.lutSelection, .customFile)
            XCTAssertEqual(preferences.lutSelection, .customFile)
            XCTAssertEqual(preferences.customFileName(for: .dLog), "b.cube")

            assist.clearCustomFile("b.cube")
            XCTAssertEqual(assist.lutSelection, .auto)
            XCTAssertEqual(preferences.lutSelection, .auto)
            XCTAssertNil(preferences.selectedCustomFileName)
            XCTAssertNil(preferences.customFileName(for: .dLog))
        }

        /// The playback picker keeps the clip's colour; live binds the camera's.
        func testPickerBindKeepsPlaybackColour() {
            let assist = state(looks())
            assist.syncLUT(to: .dLog2)
            assist.adoptPlaybackColor(.dLog)
            assist.bindLUTPicker(live: .dLog2, inPlayback: true)
            XCTAssertEqual(assist.monitorColorMode, .dLog)
            XCTAssertEqual(assist.looks.preferences.lastMonitorColorMode, .dLog2)
            assist.bindLUTPicker(live: .normal, inPlayback: false)
            XCTAssertEqual(assist.monitorColorMode, .normal)
        }

        private static let copy = LUTPickerCopy(
            officialTab: "SIMULATED", officialLockedCaption: "Locked", officialCaption: "Official",
            customEmptyHint: "Import here")
        private static let context = LUTPickerContext(
            colorMode: .dLog, isPhoto: false, inPlayback: false, family: .fallback,
            cameraName: "SIMULATED", isWatching: false)

        /// A2-60: Pocket and Insta reach the shared picker as three typed libraries, the same tabs,
        /// rows and actions their own picker had.
        func testPickerLibrariesAreTheOfficialCreativeAndImportedTabs() throws {
            let assist = state(looks())
            let libraries = assist.lutPickerLibraries(context: Self.context, copy: Self.copy)
            XCTAssertEqual(libraries.map(\.title), ["SIMULATED", "Creative", "Custom"])
            XCTAssertEqual(libraries.map(\.layout), [.drum, .drum, .files])
            XCTAssertEqual(libraries.map(\.isCurrent), [true, false, false])
            XCTAssertEqual(libraries[0].drumTitle, LUTSelection.officialAuto.title)
            XCTAssertEqual(libraries[1].drumTitle, LUTSelection.creativeMono.title)
            XCTAssertEqual(libraries[1].caption, "Looks for the displayed picture")
            XCTAssertEqual(libraries[2].empty?.hint, "Import here")

            libraries[1].select(try XCTUnwrap(libraries[1].entry(titled: LUTSelection.creativeWarm.title)))
            XCTAssertEqual(assist.lutSelection, .creativeWarm)
            let creative = assist.lutPickerLibraries(context: Self.context, copy: Self.copy)
            XCTAssertEqual(creative.map(\.isCurrent), [false, true, false])
            XCTAssertEqual(creative[1].selectedID, LUTSelection.creativeWarm.rawValue)
            XCTAssertNil(creative[0].selectedID)

            // Live Photo shows the official catalogue for reference only.
            let photo = LUTPickerContext(
                colorMode: .dLog, isPhoto: true, inPlayback: false, family: .fallback,
                cameraName: nil, isWatching: false)
            let official = assist.lutPickerLibraries(context: photo, copy: Self.copy)[0]
            XCTAssertFalse(official.allowsSelection)
            XCTAssertEqual(official.caption, LUTPickerCopy.photoRec709Caption)
        }

        /// A2-60: the typed library slot rests the drum on the applied look, then the look a tab
        /// switch applies, and resolves rows and stars by title.
        func testLibraryDrumRestsOnTheAppliedLookThenTheRepresentative() {
            let looks = ["a", "b", "b"].enumerated().map {
                LUTPickerLibrary.Entry(id: "\($0.offset)", title: $0.element)
            }
            func library(selected: String?, representative: LUTPickerLibrary.Entry?) -> LUTPickerLibrary {
                LUTPickerLibrary(
                    title: "SIMULATED", entries: looks, isCurrent: selected != nil, selectedID: selected,
                    representative: representative, markedIDs: ["2"], select: { _ in })
            }
            XCTAssertEqual(library(selected: "1", representative: looks[0]).drumTitle, "b")
            XCTAssertEqual(library(selected: nil, representative: looks[1]).drumTitle, "b")
            XCTAssertEqual(library(selected: nil, representative: nil).drumTitle, "a")
            XCTAssertEqual(library(selected: nil, representative: nil).entry(titled: "b")?.id, "1")
            XCTAssertEqual(library(selected: nil, representative: nil).markedTitles, ["b"])
            XCTAssertEqual(
                LUTPickerLibrary(title: "", entries: [], isCurrent: false, selectedID: nil, select: { _ in })
                    .drumTitle, "")
        }

        /// A1-37: the DJI-style looks apply the exposure offset in their shared cube.
        func testOfficialLooksApplyTheLUTExposure() {
            XCTAssertTrue(looks().appliesLUTExposure)
        }
    }
#endif
