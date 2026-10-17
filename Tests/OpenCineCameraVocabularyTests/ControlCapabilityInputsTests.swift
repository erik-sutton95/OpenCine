import OpenCineCore
import OpenCineCameraVocabulary
import Testing

@Suite struct ControlCapabilityInputsTests {
    @Test func dynamicInputsPreserveUnknownReadOnlyAndDeclaredValues() {
        let domain = SettingDomain(choices: [.iso(.manual(800))])
        let snapshot = CapabilitySnapshot(descriptors: [SettingDescriptor(.iso, domain: domain),
            SettingDescriptor(.shutter, access: .readOnly)])
        let source = ControlCapabilities(snapshot: snapshot,
            profile: CameraCaptureProfile(supportsFocusMode: true, supportsZoom: true))
        let controls = source.restricting([
            .iso: ControlStatus(support: .supported, access: .readOnly),
            .shutter: ControlStatus(support: .supported),
            .focus: ControlStatus(support: .unsupported),
            .zoom: ControlStatus(support: .unknown),
            .audio: ControlStatus(support: .supported),
        ])
        #expect(controls.iso.isShown && !controls.iso.isOffered)
        #expect(controls.iso.offer?.setting?.domain == domain)
        #expect(controls.shutter.isShown && !controls.shutter.isOffered)
        #expect(controls.focus.support == .unsupported)
        #expect(controls.focus.offer == nil)
        #expect(controls.zoom.support == .unknown)
        #expect(!controls.zoom.isOffered)
        #expect(controls.audio.support == .unknown, "transport permission invents no camera support")
        #expect(source.focus.isOffered, "a derived restriction does not mutate the source")
        #expect(source.restricting([:]) == source)
    }
}
