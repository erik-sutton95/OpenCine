import OpenCineAppKit
import OpenCineCore
import SwiftUI
import Testing

@MainActor
@Suite struct IntegrationSlotsCompatibilityTests {
    @available(macOS 14, *)
    @Test func publishedLegacyCallbackRemainsMutableAndKeepsItsEscapingReply() {
        #expect(IntegrationSlots().addRoute == nil)
        var calls = 0
        var reply: ((RouteDraft?) -> Void)?
        var selected: RouteKind?
        var slots = IntegrationSlots(
            addRoute: { _, done in
                calls += 1
                reply = done
                return AnyView(EmptyView())
            },
            addSetup: { _, _ in
                AddSetupFlow(
                    chooser: AddSetupChooser(title: "Typed", detail: "", options: []),
                    onSelect: { _ in })
            })
        let camera = CamerasModelTests.camera
        let view = slots.addRoute?(camera) { selected = $0?.kind }
        #expect(view != nil && calls == 1)
        reply?(RouteDraft(kind: .phoneHotspot))
        #expect(selected == .phoneHotspot)
        slots.addRoute = nil
        #expect(slots.addRoute == nil)
        slots.addRoute = { _, done in
            calls += 1
            done(nil)
            return AnyView(EmptyView())
        }
        _ = slots.addRoute?(camera) { selected = $0?.kind }
        #expect(calls == 2 && selected == nil)
    }
}
