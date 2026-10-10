import Testing

@testable import OpenCineNikon

@Suite("Connection phase timeouts")
struct CameraConnectionTimeoutTests {
    @Test("Every machine-driven phase is bounded")
    func machineDrivenPhasesAreBounded() {
        for phase in [
            CameraConnectionPhase.joiningWiFi, .discovering, .handshaking, .preparingLiveView,
        ] {
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: false) != nil)
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: true) != nil)
        }
    }

    @Test("Phases that wait on a person are never timed out")
    func operatorPhasesAreUnbounded() {
        for phase in [
            CameraConnectionPhase.idle, .readyToJoin, .pairing, .confirmOnCamera, .connected,
            .failed,
        ] {
            #expect(CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: false) == nil)
        }
    }

    @Test("USB gets the longer handshake budget for the card enumeration")
    func usbHandshakeBudgetIsLarger() {
        let wifi = CameraConnectionTimeout.budgetSeconds(for: .handshaking, isUSB: false)
        let usb = CameraConnectionTimeout.budgetSeconds(for: .handshaking, isUSB: true)
        #expect((usb ?? 0) > (wifi ?? 0))
    }

    @Test("Timeout copy names the phase's actual failure and stays actionable")
    func timeoutCopy() {
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .discovering, deviceName: "Nikon ZR")
                .contains("Connect to PC"))
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .handshaking, deviceName: "Nikon ZR")
                .contains("Nikon ZR"))
        #expect(
            CameraConnectionTimeout.timeoutMessage(phase: .joiningWiFi, deviceName: "")
                .contains("the camera"))
    }
}
