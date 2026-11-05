import Testing

@testable import OpenCineVirtualCamera

@Test func platformClientWithUnavailableSigningMetadataIsAccepted() {
    #expect(ProducerAdmission.accepts(signingHint: "unknown"))
    #expect(ProducerAdmission.accepts(signingHint: nil))
    #expect(ProducerAdmission.accepts(signingHint: "com.opencapture.openzcine.module"))
}

@Test func explicitForeignSigningHintIsDenied() {
    #expect(!ProducerAdmission.accepts(signingHint: "com.example.other"))
    #expect(!ProducerAdmission.accepts(signingHint: "com.opencapture.openzcine.attacker"))
}

@Test func anyCameraModuleIdentityIsAccepted() {
    #expect(ProducerAdmission.accepts(signingHint: "com.opencapture.openpocketcine.module"))
    #expect(!ProducerAdmission.accepts(signingHint: "com.opencapture.opencine.module.evil"))
}
