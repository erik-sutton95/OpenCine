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

        /// Product ruling 2026-10-16: a camera that has not reported its colour mode, or reports
        /// Dolby Vision, has no known source curve; LUT exposure is not offered until it does.
        func testTheSourceCurveIsUnknownUntilTheCameraReportsALogOrRec709Mode() {
            let looks = looks()
            let assist = state(looks)
            assist.syncLUT(to: nil)
            XCTAssertNil(looks.sourceTransfer)
            XCTAssertFalse(looks.appliesLUTExposure)
            XCTAssertFalse(assist.sourceCurveKnown)
            assist.syncLUT(to: .dolbyVision)
            XCTAssertNil(looks.sourceTransfer)
            XCTAssertFalse(assist.offers(.falseColor))
            assist.syncLUT(to: .dLog)
            XCTAssertEqual(looks.sourceTransfer, .dlog)
            XCTAssertTrue(looks.appliesLUTExposure)
            XCTAssertTrue(assist.offers(.falseColor) && assist.offers(.zebra))
            assist.syncLUT(to: nil, isPhoto: true)
            XCTAssertEqual(looks.sourceTransfer, .rec709, "Photo reads Rec.709")
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
    }
#endif
