import Foundation
import Testing
@testable import OpenCineCore

@Suite struct CameraNetworkPermissionTests {
    @Test func waitingIsNeitherDenialNorApproval() {
        var observation = CameraNetworkPermissionObservation()
        #expect(observation.state == .unknown)
        let attempt = observation.begin()
        observation.observe(.waiting, attempt: attempt)
        #expect(observation.state == .requested)
        #expect(!CameraNetworkPermissionPolicy.isLocalNetworkDenied(dnsErrorCode: nil, pathDenied: false))
        #expect(!CameraNetworkPermissionPolicy.isLocalNetworkDenied(dnsErrorCode: -65537, pathDenied: false))
    }

    @Test func onlyExplicitPolicyEvidenceIsDenial() {
        #expect(CameraNetworkPermissionPolicy.isLocalNetworkDenied(dnsErrorCode: -65570, pathDenied: false))
        #expect(CameraNetworkPermissionPolicy.isLocalNetworkDenied(dnsErrorCode: nil, pathDenied: true))
        var observation = CameraNetworkPermissionObservation()
        let attempt = observation.begin()
        observation.observe(.policyDenied, attempt: attempt)
        #expect(observation.state == .denied)
        observation.observe(.waiting, attempt: attempt)
        #expect(observation.state == .denied)
        observation.observe(.operationSucceeded, attempt: attempt)
        #expect(observation.state == .allowed)
    }

    @Test func retiredEvidenceCannotPoisonOrStopTheSuccessor() {
        var observation = CameraNetworkPermissionObservation()
        let old = observation.begin()
        let current = observation.begin()
        observation.observe(.policyDenied, attempt: old)
        observation.retire(attempt: old)
        #expect(observation.state == .requested)
        observation.observe(.operationSucceeded, attempt: current)
        #expect(observation.state == .allowed)
        observation.retire(attempt: current)
        observation.observe(.policyDenied, attempt: current)
        #expect(observation.state == .allowed)
    }
}
