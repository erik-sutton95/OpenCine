#if os(iOS)
import MonitorPresentation
import OpenCineCameraControls
import SwiftUI
import Testing

/// A1-23: a tool with source-supplied options (Z's level styles) opens its inspector from the
/// palette, as instant review already did.
@MainActor
@Suite struct MonitorOperatorSignalOptionsTests {
    @Test func sourceSuppliedOptionsOpenTheirTool() {
        let none = MonitorOperatorSignalOptions()
        #expect(!none.offers(.level) && !none.offers(.instantReview))
        let supplied = MonitorOperatorSignalOptions(
            level: AnyView(Text("Level style")), instantReview: AnyView(Text("Hold")))
        #expect(supplied.offers(.level) && supplied.offers(.instantReview))
        #expect(!supplied.offers(.waveform), "shared tools keep their own configuration")
    }
}
#endif
