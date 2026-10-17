import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import Testing

@Suite struct ControlDisplaySectionsTests {
    @Test func displaySectionsFollowTypedSupportWithoutInventingHostServices() {
        let hostSections = Set(MonitorDisplayChrome.Section.allCases)
            .subtracting([.zoomChip, .gimbalStick, .color])
        let statuses: [ControlStatus] = [.init(support: .unknown), .init(support: .unsupported),
            .init(support: .supported), .init(support: .supported, access: .readOnly)]
        for status in statuses {
            var controls = ControlCapabilities()
            controls.zoom = .init(support: status.support, access: status.access)
            controls.gimbal = .init(support: status.support, access: status.access)
            controls.codecColor = .init(support: status.support, access: status.access)
            let sections = controls.displaySections
            #expect(sections.contains(.zoomChip) == status.isOffered)
            #expect(sections.contains(.gimbalStick) == status.isOffered)
            #expect(sections.contains(.color) == status.isShown)
            #expect(sections.isSuperset(of: hostSections))
        }
        var controls = ControlCapabilities()
        controls.codecColor = .supported(.init(codecs: [.init(id: "codec", label: "Codec")]))
        #expect(!controls.displaySections.contains(.color), "known codec-only values have no color chip")
        controls.codecColor = .supported(.init(colors: [.init(id: "log", label: "Log")]), access: .readOnly)
        #expect(controls.displaySections.contains(.color), "a real read-only color remains a readout")
        controls.codecColor.support = .unknown
        #expect(!controls.displaySections.contains(.color), "values do not invent support")
    }
}
