#if os(iOS)
import OpenCineHostedAccessibility
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
