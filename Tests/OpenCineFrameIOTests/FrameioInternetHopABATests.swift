import OpenCineFrameIO
import Testing

/// SIMULATED route publication; the original end remains the only cleanup admission.
@Suite struct FrameioInternetHopABATests {
    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func currentEndCanPublishButCannotEndTwice() {
        var route = FrameioInternetHop()
        let captured = route.begin()
        #expect(!route.ended(captured))
        let accepted = route.end(captured)
        #expect(accepted && route.ended(captured))
        let repeated = route.end(captured)
        #expect(!repeated && route.ended(captured))
    }
    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func successorBeginAndEndCannotReviveTheOldPublication() {
        var route = FrameioInternetHop()
        let old = route.begin()
        let accepted = route.end(old)
        #expect(accepted && route.ended(old))
        let successor = route.begin()
        #expect(!route.ended(old) && !route.ended(successor))
        let successorAccepted = route.end(successor)
        #expect(successorAccepted && route.ended(successor) && !route.ended(old))
    }
    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func transferAndIndependentOwnerCannotBorrowEndedPublication() throws {
        var route = FrameioInternetHop()
        var other = FrameioInternetHop()
        let old = route.begin()
        let transferred = route.transfer(old)
        let successor = try #require(transferred)
        let accepted = route.end(successor)
        #expect(accepted && route.ended(successor) && !route.ended(old))
        let otherToken = other.begin()
        let otherAccepted = other.end(otherToken)
        #expect(otherAccepted && !route.ended(otherToken) && !other.ended(successor))
    }
}
