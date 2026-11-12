import Insta360Apple
import OpenCineCore
import Testing

/// Which saved Luna routes may join a multicam group. Kotlin twin: `LunaMulticamPolicyTest`, same
/// test names.
@Suite struct LunaMulticamPolicyTests {
    private static let camera = CameraDeviceID.durable("IAQEB2502ABCDE", integration: LunaCameraSession.integration)
    private static let other = CameraDeviceID.durable("IAQEB2502FGHIJ", integration: LunaCameraSession.integration)

    private static func route(_ kind: RouteKind) -> SavedRoute { SavedRoute(key: kind.rawValue, kind: kind) }

    @Test func routerAndHotspotRoutesQualify() {
        for kind in [RouteKind.infrastructureNetwork, .phoneHotspot] {
            #expect(LunaMulticamPolicy.qualification(route: Self.route(kind), device: Self.camera, members: [Self.other]) == .qualified)
            #expect(LunaMulticamPolicy.qualification(route: Self.route(kind), device: nil, members: [Self.other]) == .qualified)
        }
    }

    @Test func aCameraAlreadyInTheGroupIsRefused() {
        for kind in [RouteKind.infrastructureNetwork, .phoneHotspot] {
            #expect(
                LunaMulticamPolicy.qualification(route: Self.route(kind), device: Self.camera, members: [Self.camera, Self.other])
                    == .refused(.alreadyMember))
        }
    }

    @Test func theCameraAccessPointAndOtherRoutesAreRefused() {
        for kind in [RouteKind.cameraAccessPoint, .usb, .captureDevice] {
            #expect(
                LunaMulticamPolicy.qualification(route: Self.route(kind), device: Self.camera, members: [])
                    == .refused(.unsupportedConfiguration))
        }
    }

    @Test func noSavedRouteIsNotReachable() {
        #expect(LunaMulticamPolicy.qualification(route: nil, device: Self.camera, members: []) == .refused(.notReachable))
    }
}
