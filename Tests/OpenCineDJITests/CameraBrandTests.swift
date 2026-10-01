import Foundation
import Testing

@testable import OpenCineDJI

/// The Xtra Edge Pro is a rebadged Osmo Action 5 Pro and advertises the *same* model id `0x0015`,
/// so only the hardware OUI separates the two — and only the Xtra speaks 10004 with no TCP-7001
/// poke. Mirrors Osmosis `ble/CameraModelBrandTest.kt`, where the Edge Pro is hardware-verified.
@Suite struct CameraBrandTests {
    @Test func xtraOuiWinsOverEveryNameAndCompanyId() {
        #expect(CameraBrand.of(address: "EC:9E:EA:11:22:33", name: "XtraEdgePro-C2D8") == .xtra)
        // A DJI-looking name loses to the hardware OUI.
        #expect(CameraBrand.of(address: "EC:9E:EA:11:22:33", name: "OsmoAction5Pro-1234") == .xtra)
        // An Xtra carries DJI's company id too; its own OUI still has to win, or it is handed
        // the 9004 config it cannot answer.
        #expect(
            CameraBrand.of(address: "EC:9E:EA:00:00:01", name: "XtraEdgePro-2DCA", djiCid: true)
                == .xtra)
    }

    @Test func nameTellWithoutAMacIsXtra() {
        // iOS has no MAC; the advertised name is the brand tell.
        #expect(CameraBrand.of(address: nil, name: "XtraEdgePro-2DCA16") == .xtra)
        let xtra = CameraModel.resolve(
            modelId: 0x0015,
            name: "XtraEdgePro-2DCA16",
            brand: CameraBrand.of(address: nil, name: "XtraEdgePro-2DCA16"))
        #expect(xtra.datalinkPort == 10004)
        #expect(xtra.tcpPoke == false)
    }

    @Test func djiHardwareStaysDji() {
        #expect(CameraBrand.of(address: "58:B8:58:CC:F8:23", name: "OsmoPocket4P-AAAA") == .dji)
        #expect(CameraBrand.of(address: nil, name: "OsmoNano-5A31") == .dji)
        // No OUI, no name tell — only the company id identifies it.
        #expect(CameraBrand.of(address: "AA:BB:CC:00:00:01", name: "1001", djiCid: true) == .dji)
        #expect(CameraBrand.of(address: "AA:BB:CC:00:00:01", name: "1001") == .unknown)
    }

    @Test func xtraResolvesTo10004WithNoPoke() {
        let xtra = CameraModel.resolve(modelId: 0x0015, name: "XtraEdgePro-2DCA16", brand: .xtra)
        #expect(xtra.name == "Xtra Edge Pro")
        #expect(xtra.datalinkPort == 10004)
        #expect(xtra.tcpPoke == false)

        // The genuine Action 5 Pro shares the model id and keeps the DJI-standard config.
        let dji = CameraModel.resolve(modelId: 0x0015, name: "OsmoAction5Pro-1234", brand: .dji)
        #expect(dji.name == "Osmo Action 5 Pro")
        #expect(dji.datalinkPort == 9004)
        #expect(dji.tcpPoke == true)
    }

    @Test func otherXtraRebadgesKeepTheirNames() {
        #expect(CameraModel.resolve(modelId: 0x0019, name: nil, brand: .xtra).name == "Xtra Atto")
        #expect(CameraModel.resolve(modelId: 0x0020, name: nil, brand: .xtra).name == "Xtra Muse")
    }

    @Test func resolveWithoutABrandIsUnchanged() {
        #expect(CameraModel.resolve(modelId: 0x0019, name: "OsmoNano-5A31").datalinkPort == 9004)
        #expect(CameraModel.resolve(modelId: 0x0019, name: "OsmoNano-5A31").name == "Osmo Nano")
    }
}
