#if os(iOS)
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// The walk every hosted test shares must end on the trees that hung or misled its nine copies.
@MainActor
final class HostedAccessibilityTests: XCTestCase {
    func testAnAlertStyleNotFoundCountIsALeaf() {
        let alert = Stub(count: NSNotFound)
        XCTAssertEqual(HostedAccessibility.elements(in: alert), [alert])
    }

    func testACycleIsVisitedOnce() {
        let first = Stub(), second = Stub()
        first.children = [second]
        second.children = [first]
        XCTAssertEqual(HostedAccessibility.elements(in: first), [first, second])
    }

    func testAnEndlesslyGeneratedTreeStopsAtTheBound() {
        XCTAssertEqual(HostedAccessibility.elements(in: Generating(), limit: 40).count, 40)
        XCTAssertEqual(HostedAccessibility.elements(in: Stub(count: Int.max - 1), limit: 40).count, 40)
    }

    func testHiddenAndTransparentSubtreesAreSkipped() {
        let root = UIView()
        let hidden = UIView(), transparent = UIView(), silenced = UIView(), shown = UILabel()
        hidden.isHidden = true
        transparent.alpha = 0
        silenced.accessibilityElementsHidden = true
        for view in [hidden, transparent, silenced] { view.addSubview(UILabel()) }
        for view in [hidden, transparent, silenced, shown] { root.addSubview(view) }
        XCTAssertEqual(HostedAccessibility.elements(in: root), [root, shown])
    }

    func testTheWalkIsTheUnionOfElementsIndexedElementsAndSubviews() {
        let root = Container()
        let vended = Stub(), indexed = Stub(), subview = UIView()
        root.vended = [vended]
        root.indexed = [indexed]
        root.addSubview(subview)
        XCTAssertEqual(HostedAccessibility.elements(in: root), [root, vended, indexed, subview])
        subview.accessibilityIdentifier = "monitor.fixture"
        XCTAssertEqual(HostedAccessibility.identifier(subview), "monitor.fixture")
        XCTAssertNil(HostedAccessibility.identifier(NSObject()))
    }

    func testLeavesEndAtAnElementAndPreferVendedChildren() {
        let root = Container()
        let element = UIView(), nested = UIView(), vended = Stub(), ignoredSubview = UIView()
        element.isAccessibilityElement = true
        nested.isAccessibilityElement = true
        element.addSubview(nested)
        let group = Container()
        group.vended = [vended, element]
        group.addSubview(ignoredSubview)
        root.indexed = [Stub()]
        root.addSubview(group)
        vended.children = []
        XCTAssertEqual(HostedAccessibility.reachable(in: root), [root, group, vended, element])
        XCTAssertEqual(HostedAccessibility.leaves(in: root), [element])
        XCTAssertEqual(HostedAccessibility.reachable(in: Generating(), limit: 40).count, 40)
    }

    /// The durable fix for walks that found nothing on a fresh simulator: the walk itself turns
    /// on the accessibility runtime, so SwiftUI vends its tree however the simulator was made.
    func testAWalkSeesSwiftUINodesWithoutSimulatorAccessibilitySetup() async throws {
        #if targetEnvironment(simulator)
            XCTAssertTrue(HostedAccessibility.enableRuntime(), "libAccessibility runtime switches must resolve")
            let live = await HostedAccessibility.awaitRuntime()
            XCTAssertTrue(live, "SwiftUI must vend its tree once the runtime is on")
        #endif
        let host = UIHostingController(rootView: Text("SIMULATED probe").accessibilityIdentifier("probe.node"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var found = false
        for _ in 0..<100 where !found {
            host.view.layoutIfNeeded()
            found = HostedAccessibility.leaves(in: host.view).contains { HostedAccessibility.identifier($0) == "probe.node" }
            if !found { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(found, "SwiftUI must vend its accessibility tree to the hosted walk")
    }
}

private final class Stub: NSObject {
    var children: [NSObject] = []
    private let count: Int?
    init(count: Int? = nil) { self.count = count }
    override var accessibilityElements: [Any]? {
        get { children }
        set {}
    }
    override func accessibilityElementCount() -> Int { count ?? 0 }
    override func accessibilityElement(at index: Int) -> Any? { Stub() }
}

private final class Generating: NSObject {
    override var accessibilityElements: [Any]? {
        get { [Generating()] }
        set {}
    }
}

private final class Container: UIView {
    var vended: [NSObject] = []
    var indexed: [NSObject] = []
    override var accessibilityElements: [Any]? {
        get { vended }
        set {}
    }
    override func accessibilityElementCount() -> Int { indexed.count }
    override func accessibilityElement(at index: Int) -> Any? { indexed[index] }
}
#endif
