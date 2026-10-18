import Foundation

// SIMULATED developer host and generated UI-test data only. Never a package product.
enum NativeCancelContract {
    static let title = "Remove this SIMULATED clip?"
    static let message = "Its camera master and backup copies are removed too."
    static let receiptPrefix = "SIMULATED-native-cancel-"
    static let readerPrefix = "SIMULATED-native-reader-"
    // The frozen SIMULATED screen's complete actionable inventory, excluding the native popup.
    static let mainButtons: Set<String> = [
        "Previous clip", "Next clip", "Favorite clip", "Clip information", "Share clip",
        "Delete clip from camera", "Back to media", "Back 15 seconds", "Play",
        "Forward 15 seconds", "Conform preview", "Mute", "Loop playback", "Hide playback controls",
    ]
    static let scrubber = "Playback position"
}

struct NativeCancelItem: Codable, Equatable {
    let owner: UUID
    let revision: UInt64
}

struct NativeCancelRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = min(rect.origin.x, rect.origin.x + rect.size.width)
        y = min(rect.origin.y, rect.origin.y + rect.size.height)
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
    func contains(_ point: NativeSystemPoint, margin: Double = 0) -> Bool {
        point.x >= x - margin && point.x < x + width + margin
            && point.y >= y - margin && point.y < y + height + margin
    }
    func contains(_ other: NativeCancelRect) -> Bool {
        other.x >= x && other.y >= y && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
    var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

// Both public APIs describe screen-space frames. The selected screen supplies the unit scale.
func nativeExternalControlFrameMatches(
    _ external: NativeCancelRect, _ native: NativeCancelRect, scale: Double?
) -> Bool {
    guard let scale, scale.isFinite, scale > 0, external.finite, native.finite else { return false }
    func deviceEdges(_ frame: NativeCancelRect) -> [Double] {
        [
            frame.x * scale, frame.y * scale,
            (frame.x + frame.width) * scale, (frame.y + frame.height) * scale,
        ]
    }
    let externalEdges = deviceEdges(external)
    let nativeEdges = deviceEdges(native)
    guard externalEdges.allSatisfy(\.isFinite), nativeEdges.allSatisfy(\.isFinite) else {
        return false
    }
    return externalEdges == nativeEdges
}

struct NativeCancelAction: Codable, Equatable {
    let title: String?
    let style: Int
}

struct NativeCancelPopup: Codable {
    let identity: String
    let title: String?
    let message: String?
    let actions: [NativeCancelAction]
    let frame: NativeCancelRect
    let presentationFrame: NativeCancelRect
    let mountedInHostWindow: Bool
    let renderedStrings: [String]
    let viewWalkAtLimit: Bool
    let presentationClass: String
    let modalStyle: Int
    let horizontalSizeClass: Int
    let verticalSizeClass: Int
}

// The application writes this value from native observations and actual shared-screen callbacks.
// The driver has no endpoint for setting or acknowledging cancellation or presentation state.
struct NativeCancelReceipt: Codable {
    let schema: Int
    let nonce: String
    let sourceSeal: String
    let bundleID: String
    let simulatorID: String
    let processID: Int32
    let sequence: UInt64
    let observedAt: TimeInterval
    let requestID: UUID
    let item: NativeCancelItem
    let capturedItems: [NativeCancelItem]
    let captureRequestIDs: [UUID]
    let confirmed: [UUID]
    let cancelled: [UUID]
    let deletedCount: Int
    let activeRequestIDs: [UUID]
    let retiredRequestIDs: [UUID]
    let foreground: Bool
    let keyWindow: Bool
    let rootMounted: Bool
    let sceneID: String
    let windowIdentity: String
    let windowFrame: NativeCancelRect
    let screenFrame: NativeCancelRect
    let rootFillsScene: Bool
    let orientation: Int
    let popup: NativeCancelPopup?
    let dialogWindowGone: Bool
    let presentingControllerGone: Bool
    let mode: String
    let windows: [NativeSystemWindow]
    let systemDismissal: NativeSystemDismissalProof?
    let systemDismissalRejections: [String]
}

struct NativeSystemPoint: Codable, Equatable {
    let x: Double
    let y: Double
    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    var point: CGPoint { CGPoint(x: x, y: y) }
    var finite: Bool { x.isFinite && y.isFinite }
}

struct NativeSystemWindow: Codable {
    let identity: String
    let sceneID: String?
    let frame: NativeCancelRect
    let key: Bool
    let hidden: Bool
    let rootController: String?
}

// Every node is an observation of an actual UIView, never a constructed dismissal surface.
// Class names are diagnostic only. The proof uses public object ownership and native hit routing.
struct NativeSystemView: Codable, Equatable {
    let identity: String
    let parent: String?
    let window: String?
    let diagnosticClass: String
    let identifier: String?
    let label: String?
    let frame: NativeCancelRect
    let hidden: Bool
    let alpha: Double
    let interactive: Bool
    let control: Bool
    let sharedContent: Bool
    let popupContent: Bool
}

struct NativeSystemDismissalProof: Codable, Equatable {
    let popover: String
    let presentation: String
    let presented: String
    let expectedPresented: String
    let presenting: String
    let expectedPresenting: String
    let presentingInHostChain: Bool
    let container: String
    let popoverContainer: String
    let containerWindow: String?
    let presentedView: String
    let sharedView: String
    let window: String
    let sceneID: String
    let selectedScreen: String
    let screenScale: Double?
    let sceneWindowIDs: [String]
    let otherWindowHits: [NativeSystemOtherWindowHit]
    let modalStyle: Int
    let presentationStyle: Int?
    let arrowDirection: UInt?
    let fullscreen: Bool?
    let neutralBackground: NativeSystemNeutralBackground?
    let modalInPresentation: Bool
    let transitioning: Bool
    let windowBounds: NativeCancelRect
    let safeWindowBounds: NativeCancelRect
    let screenBoundsInWindow: NativeCancelRect
    let containerBoundsInWindow: NativeCancelRect
    let visible: NativeCancelRect
    let pointInWindow: NativeSystemPoint
    let pointOnScreen: NativeSystemPoint
    let convertedBack: NativeSystemPoint
    let popupFrameOnScreen: NativeCancelRect
    let presentationFrameOnScreen: NativeCancelRect
    let regions: [NativeSystemView]
    let hitChain: [NativeSystemView]
    let controlsAtPoint: [NativeSystemView]
    let passthroughViews: [NativeSystemView]
    let passthroughAtPoint: [String]
    let walkAtLimit: Bool
    var rejections: [String]
}

struct NativeSystemOtherWindowHit: Codable, Equatable {
    let identity: String
    let sceneID: String?
    let screen: String
    let hidden: Bool
    let alpha: Double
    let frame: NativeCancelRect
    let interactive: Bool
    let pointInWindow: NativeSystemPoint?
    let convertedScreenPoint: NativeSystemPoint?
    let hitTestObserved: Bool
    let hitIdentity: String?
}

struct NativeSystemActionable: Codable, Equatable {
    let identity: String
    let label: String?
    let kind: String
    let frame: NativeCancelRect
    let customActions: Int
}

struct NativeSystemNeutralBackground: Codable, Equatable {
    let item: NativeCancelItem?
    let canvas: NativeCancelRect
    let feed: NativeCancelRect
    let zoomScale: Double
    let zoomOffset: NativeSystemPoint
    let hostBounds: NativeCancelRect
    let hostFrameOnScreen: NativeCancelRect
    let hostTransformIdentity: Bool
    let pointInHost: NativeSystemPoint
    let pointBackInWindow: NativeSystemPoint
    let actionables: [NativeSystemActionable]
    let publicWalkCount: Int
    let publicWalkAtLimit: Bool
    let opaqueObjects: Int
}

// Pure Foundation value policy, shared by the real observer and the separate UI driver.
// It admits one contract-defined outside-dismissal attempt, never cancellation success.
func nativeContractInputRejections(
    _ proof: NativeSystemDismissalProof, item: NativeCancelItem, windowFrame: NativeCancelRect
) -> [String] {
    var reasons: [String] = []
    if proof.modalStyle != 7 || proof.presentationStyle != 7 || proof.fullscreen == nil
        || ![UInt(1), 2, 4, 8].contains(proof.arrowDirection ?? 0)
        || proof.transitioning || proof.modalInPresentation
        || proof.popover != proof.presentation || proof.presented != proof.expectedPresented
        || proof.presenting != proof.expectedPresenting || !proof.presentingInHostChain
        || proof.container != proof.popoverContainer || proof.containerWindow != proof.window
    {
        reasons.append("Actual active unadapted public popover ownership is missing or ambiguous")
    }
    if proof.walkAtLimit || !proof.pointInWindow.finite || !proof.pointOnScreen.finite
        || !proof.visible.finite || proof.visible.width <= 40
        || proof.visible.height <= 40
        || proof.pointInWindow
            != NativeSystemPoint(
                x: proof.visible.x + 16, y: proof.visible.y + proof.visible.height - 16)
        || !proof.visible.contains(proof.pointInWindow)
        || proof.convertedBack != proof.pointInWindow
        || !windowFrame.contains(proof.pointOnScreen)
        || !proof.popupFrameOnScreen.finite || !proof.presentationFrameOnScreen.finite
        || proof.popupFrameOnScreen.contains(proof.pointOnScreen, margin: 1)
        || proof.presentationFrameOnScreen.contains(proof.pointOnScreen, margin: 1)
        || !proof.controlsAtPoint.isEmpty || !proof.passthroughViews.isEmpty
        || !proof.passthroughAtPoint.isEmpty
    {
        reasons.append(
            "Original point, popup exclusion, conversion, control or passthrough proof fails")
    }
    if proof.hitChain.first?.identity != proof.sharedView
        || proof.hitChain.last?.identity != proof.window
    {
        reasons.append("Selected hit is nil or not the exact frozen shared background/root chain")
    }
    for (index, node) in proof.hitChain.enumerated() {
        let root = node.identity == proof.window
        if (root
            ? index != proof.hitChain.count - 1 || node.parent != nil : node.window != proof.window)
            || node.hidden || node.alpha < 0.01 || !node.alpha.isFinite || !node.interactive
            || node.control || node.popupContent
            || (node.sharedContent && node.identity != proof.sharedView)
            || !node.frame.finite || !node.frame.contains(proof.pointOnScreen)
            || (index + 1 < proof.hitChain.count
                && node.parent != proof.hitChain[index + 1].identity)
        {
            reasons.append(
                "Unknown, interactive-content or foreign ownership in the native hit chain")
            break
        }
    }
    if proof.regions.count != 1
        || proof.regions.first.map({
            $0.parent == proof.container && $0.window == proof.window && !$0.hidden
                && $0.alpha.isFinite && $0.alpha >= 0.01 && $0.interactive && !$0.control
                && !$0.sharedContent && !$0.popupContent && $0.identifier == "PopoverDismissRegion"
                && $0.label == "dismiss popup" && $0.frame.finite
                && $0.frame.contains(proof.pointOnScreen)
        }) != true
    {
        reasons.append("Unique actual public popover region/container/window proof fails")
    }
    if proof.sceneWindowIDs.count != Set(proof.sceneWindowIDs).count
        || proof.sceneWindowIDs.filter({ $0 == proof.window }).count != 1
        || proof.otherWindowHits.map(\.identity).sorted()
            != proof.sceneWindowIDs.filter({ $0 != proof.window }).sorted()
    {
        reasons.append("Incomplete, missing or duplicated native window inventory")
    }
    for other in proof.otherWindowHits {
        let visible = !other.hidden && other.alpha >= 0.01
        // A visible window whose frame covers the point swallows the touch even when its hit
        // test there is nil, so its public frame excludes it independently of the hit chain.
        let covering = other.frame.finite && other.frame.contains(proof.pointOnScreen)
        let interception =
            other.interactive
            && (other.sceneID != proof.sceneID || other.screen != proof.selectedScreen
                || !other.hitTestObserved || other.hitIdentity != nil
                || other.pointInWindow?.finite != true
                || other.convertedScreenPoint != proof.pointOnScreen)
        if !other.alpha.isFinite || (visible && (covering || interception)) {
            reasons.append("Other-window interception is unknown or present")
            break
        }
    }
    guard let background = proof.neutralBackground else {
        return reasons + ["Actual shared-screen geometry/actionable observations are unavailable"]
    }
    if background.item != item || !background.canvas.finite || !background.hostBounds.finite
        || background.canvas != background.hostBounds || background.hostBounds != proof.windowBounds
        || background.hostFrameOnScreen != windowFrame || !background.hostTransformIdentity
        || !background.feed.finite || !background.canvas.contains(background.feed)
        || background.zoomScale != 1 || background.zoomOffset != NativeSystemPoint(x: 0, y: 0)
        || !background.pointInHost.finite
        || !background.canvas.contains(background.pointInHost)
        || background.pointInHost != proof.pointInWindow
        || background.pointBackInWindow != proof.pointInWindow
        || background.feed.contains(background.pointInHost, margin: 1)
    {
        reasons.append(
            "Actual item/canvas/feed/identity-zoom/native-coordinate neutral-point binding fails")
    }
    let buttons = background.actionables.filter { $0.kind == "button" }
    let adjustable = background.actionables.filter { $0.kind == "adjustable" }
    if background.publicWalkAtLimit || background.publicWalkCount <= 0
        || background.opaqueObjects != 0
        || buttons.count != NativeCancelContract.mainButtons.count
        || Set(buttons.compactMap(\.label)) != NativeCancelContract.mainButtons
        || adjustable.count != 1 || adjustable.first?.label != NativeCancelContract.scrubber
        || background.actionables.count != buttons.count + adjustable.count
        || Set(background.actionables.map(\.identity)).count != background.actionables.count
        || background.actionables.contains(where: {
            $0.customActions != 0 || !$0.frame.finite || !windowFrame.contains($0.frame)
                || $0.frame.contains(proof.pointOnScreen, margin: 1)
        })
    {
        reasons.append(
            "Frozen actionable coverage is incomplete, extra/custom/unknown, or contains the original point"
        )
    }
    return reasons
}
