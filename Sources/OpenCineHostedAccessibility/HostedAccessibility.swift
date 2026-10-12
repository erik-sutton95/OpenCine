#if os(iOS)
import UIKit

/// The one accessibility walk for hosted (in-process) tests, which read what UIKit and SwiftUI
/// vend to assistive technologies when XCUITest cannot observe it.
public enum HostedAccessibility {
    /// Every visible accessibility object under `root`, `root` first, in preorder: each object's
    /// `accessibilityElements`, its indexed elements and its subviews. Hidden or transparent views
    /// and `accessibilityElementsHidden` subtrees are skipped, an element count of `NSNotFound`
    /// (what a presented alert answers) is ignored, each object is visited once, and the walk
    /// stops after `limit` objects, so a cyclic or endlessly generated tree still ends.
    /// Callers filter the result, for example by `isAccessibilityElement`.
    @MainActor
    public static func elements(in root: NSObject, limit: Int = 5_000) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        var pending = [root]
        while let object = pending.popLast(), result.count < limit {
            guard seen.insert(ObjectIdentifier(object)).inserted, !object.accessibilityElementsHidden else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            result.append(object)
            var children = object.accessibilityElements as? [NSObject] ?? []
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                children += (0..<min(count, limit)).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            children += (object as? UIView)?.subviews ?? []
            pending += children.reversed()
        }
        return result
    }

    /// The object's `accessibilityIdentifier`, which `NSObject` itself does not declare.
    @MainActor
    public static func identifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }
}
#endif
