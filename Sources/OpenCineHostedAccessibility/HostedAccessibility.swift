#if os(iOS)
import Darwin
import SwiftUI
import UIKit

/// The one accessibility walk for hosted (in-process) tests, which read what UIKit and SwiftUI
/// vend to assistive technologies when XCUITest cannot observe it.
///
/// Test support only: hosted test bundles link this module, app products never do.
public enum HostedAccessibility {
    /// Turns on this process's accessibility runtime, once; later calls do nothing.
    ///
    /// SwiftUI builds its accessibility tree only while the runtime is on. A fresh simulator has
    /// it off (and an XCUITest run can turn it off again), so without this a walk finds no SwiftUI
    /// node and the result depends on how the simulator was prepared. Every walk below calls it;
    /// a test that mounts a view before its first walk calls it in `setUp`, so the first render
    /// already builds the tree.
    ///
    /// On a simulator it loads `libAccessibility` and switches on application accessibility, the
    /// setting `scripts/ios-private-simulator.py` writes; the simulator keeps it afterwards. It
    /// leaves automation off: with automation switched on in a booted simulator, later processes
    /// re-evaluated SwiftUI views more often (MotionControlDragInvalidationTests counted 5 to 12
    /// evaluations instead of 4). On a physical device it does
    /// nothing, so a test run never changes the phone's own accessibility settings; device runs
    /// keep their skip-with-reason guards. Returns whether the runtime switch was reached.
    @discardableResult
    public static func enableRuntime() -> Bool { runtime }

    /// Turns the runtime on (`enableRuntime()`) and waits until SwiftUI in this process actually
    /// vends its tree: the switch takes effect asynchronously, so a probe view is hosted in a
    /// window of its own until its node appears, for at most `timeout`. Call it before measuring
    /// anything the runtime changes, such as how often SwiftUI re-evaluates a view. Returns
    /// whether the runtime is live; later calls return at once.
    @MainActor
    @discardableResult
    public static func awaitRuntime(timeout: Duration = .seconds(5)) async -> Bool {
        if runtimeLive { return true }
        guard enableRuntime() else { return false }
        let probe = "hosted.accessibility.probe"
        let host = UIHostingController(rootView: Text("SIMULATED probe").accessibilityIdentifier(probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !runtimeLive, ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            runtimeLive = leaves(in: host.view).contains { identifier($0) == probe }
            if !runtimeLive { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return runtimeLive
    }

    @MainActor private static var runtimeLive = false

    private static let runtime: Bool = {
        #if targetEnvironment(simulator)
            guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return false }
            typealias Switch = @convention(c) (Int32) -> Void
            let names: [String] = ["_AXSApplicationAccessibilitySetEnabled"]
            let switches = names.compactMap { name in dlsym(library, name) }
            for symbol in switches { unsafeBitCast(symbol, to: Switch.self)(1) }
            return switches.count == names.count
        #else
            return false
        #endif
    }()

    /// Every visible accessibility object under `root`, `root` first, in preorder: each object's
    /// `accessibilityElements`, its indexed elements and its subviews. Hidden or transparent views
    /// and `accessibilityElementsHidden` subtrees are skipped, an element count of `NSNotFound`
    /// (what a presented alert answers) is ignored, each object is visited once, and the walk
    /// stops after `limit` objects, so a cyclic or endlessly generated tree still ends.
    /// Callers filter the result, for example by `isAccessibilityElement`.
    @MainActor
    public static func elements(in root: NSObject, limit: Int = 5_000) -> [NSObject] {
        walk(from: root, limit: limit) { object in
            (object.accessibilityElements as? [NSObject] ?? []) + indexed(object, limit: limit)
                + ((object as? UIView)?.subviews ?? [])
        }
    }

    /// What VoiceOver reaches under `root`, in reading order, `root` first: the containers it
    /// passes through and the elements it stops at. An accessibility element ends its branch;
    /// otherwise a container's `accessibilityElements` (how SwiftUI vends its nodes), else a
    /// view's subviews are walked. Indexed elements are not followed: SwiftUI's hosting views
    /// answer them with a second, partial copy of the tree. Skips and bounds as in
    /// `elements(in:)`. Use it to prove what an operator can or cannot reach: an element nested
    /// inside another element is not returned.
    @MainActor
    public static func reachable(in root: NSObject, limit: Int = 5_000) -> [NSObject] {
        walk(from: root, limit: limit) { object in
            if object.isAccessibilityElement { return [] }
            if let vended = object.accessibilityElements as? [NSObject], !vended.isEmpty { return vended }
            return (object as? UIView)?.subviews ?? []
        }
    }

    /// The elements VoiceOver stops at under `root`: `reachable(in:)` without its containers.
    @MainActor
    public static func leaves(in root: NSObject, limit: Int = 5_000) -> [NSObject] {
        reachable(in: root, limit: limit).filter(\.isAccessibilityElement)
    }

    /// The object's `accessibilityIdentifier`, which `NSObject` itself does not declare.
    @MainActor
    public static func identifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }

    @MainActor
    private static func walk(
        from root: NSObject, limit: Int, children: (NSObject) -> [NSObject]
    ) -> [NSObject] {
        enableRuntime()
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        var pending = [root]
        while let object = pending.popLast(), result.count < limit {
            guard seen.insert(ObjectIdentifier(object)).inserted, !object.accessibilityElementsHidden else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            result.append(object)
            pending += children(object).reversed()
        }
        return result
    }

    @MainActor
    private static func indexed(_ object: NSObject, limit: Int) -> [NSObject] {
        let count = object.accessibilityElementCount()
        guard count > 0, count != NSNotFound else { return [] }
        return (0..<min(count, limit)).compactMap { object.accessibilityElement(at: $0) as? NSObject }
    }
}
#endif
