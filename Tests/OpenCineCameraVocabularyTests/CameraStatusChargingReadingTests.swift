import OpenCineCameraVocabulary
import Testing

/// The charging fact every DJI producer reads (twin of Kotlin CameraStatusChargingReadingTest).
struct CameraStatusChargingReadingTests {
    @Test func declaredReportsWinAndAnAbsentReportIsNeverFalse() {
        var status = CameraStatus()
        #expect(status.chargingReading == nil, "No report is unknown, not false")
        status.charging = true
        #expect(status.chargingReading == true, "The legacy flag counts only when it says charging")
        status.chargingObservationDeclared = true
        status.chargingObservation = false
        #expect(status.chargingReading == false)
        status.chargingObservation = nil
        #expect(status.chargingReading == nil, "An invalid declared report stays unknown")
    }
}
