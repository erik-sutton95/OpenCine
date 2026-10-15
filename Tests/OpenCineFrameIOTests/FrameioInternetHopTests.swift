import Testing

@testable import OpenCineFrameIO

@Suite struct FrameioInternetHopTests {
    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func popupTransfersRestorationBeforeItsCloseCallback() {
        var route = FrameioInternetHop()
        let popup = route.begin()
        let delivery = route.transfer(popup)
        #expect(delivery != nil)
        #expect(delivery != popup)
        let popupEnded = route.end(popup)
        #expect(!popupEnded)
        #expect(route.token == delivery)
        if let delivery {
            let deliveryEnded = route.end(delivery)
            #expect(deliveryEnded)
        }
        #expect(route.token == nil)
    }

    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func lateCancelledDeliveryCannotReleaseItsSuccessor() {
        var route = FrameioInternetHop()
        let cancelled = route.begin()
        let successor = route.begin()
        let cancelledEnded = route.end(cancelled)
        #expect(!cancelledEnded)
        #expect(route.owns(successor))
        let successorEnded = route.end(successor)
        let duplicateEnded = route.end(successor)
        #expect(successorEnded)
        #expect(!duplicateEnded)
    }

    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func anotherHostCannotTransferOrReleaseTheRoute() {
        var first = FrameioInternetHop()
        var second = FrameioInternetHop()
        let firstToken = first.begin()
        let secondToken = second.begin()
        #expect(first.transfer(secondToken) == nil)
        let foreignEnded = second.end(firstToken)
        #expect(!foreignEnded)
        #expect(first.owns(firstToken))
        #expect(second.owns(secondToken))
    }

    @available(*, deprecated, message: "Exercises the retained FrameioInternetHop compatibility contract")
    @Test func aCompletedPopupCannotBeTransferredAgain() {
        var route = FrameioInternetHop()
        let popup = route.begin()
        let popupEnded = route.end(popup)
        #expect(popupEnded)
        #expect(route.transfer(popup) == nil)
        #expect(route.token == nil)
    }
}
