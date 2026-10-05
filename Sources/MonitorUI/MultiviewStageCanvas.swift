#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// Reads actual native placement at the caller's existing sampling cadence (a video
    /// backdrop's frame clock). Scrolling never publishes into the SwiftUI observation graph.
    @MainActor public final class MultiviewStageGeometry {
        weak var controller: MultiviewStageController?

        public init() {}

        /// Where slot `index` is drawn in the stage, and the part of it the strip shows.
        public func placement(_ index: Int) -> (frame: CGRect, clip: CGRect)? {
            controller?.placement(index)
        }
    }

    /// Keeps every slot's SwiftUI root and native picture host mounted while moving its
    /// existing view between the stage and the secondary-camera scroll view.
    public struct MultiviewStageCanvas<Content: View>: UIViewControllerRepresentable {
        let slots: Int
        let layout: MultiviewPresentationLayout
        let geometry: MultiviewStageGeometry
        let content: (Int) -> Content
        @Environment(\.self) private var environment

        public init(
            slots: Int, layout: MultiviewPresentationLayout, geometry: MultiviewStageGeometry,
            @ViewBuilder content: @escaping (Int) -> Content
        ) {
            self.slots = slots
            self.layout = layout
            self.geometry = geometry
            self.content = content
        }

        public func makeUIViewController(context: Context) -> MultiviewStageController {
            let controller = MultiviewStageController()
            geometry.controller = controller
            return controller
        }

        public func updateUIViewController(
            _ controller: MultiviewStageController, context: Context
        ) {
            controller.update(
                layout: layout,
                roots: (0..<slots).map { AnyView(content($0).environment(\.self, environment)) })
        }
    }

    @MainActor public final class MultiviewStageController: UIViewController, UIScrollViewDelegate {
        private var hosts: [UIHostingController<AnyView>] = []
        private var geometry: MultiviewPresentationLayout?
        private let strip = UIScrollView()
        private let edgeMask = CAGradientLayer()
        private var previousEdges: [Bool] = []

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.clipsToBounds = true
            strip.backgroundColor = .clear
            strip.showsVerticalScrollIndicator = false
            strip.showsHorizontalScrollIndicator = false
            strip.contentInsetAdjustmentBehavior = .never
            strip.delegate = self
            strip.accessibilityIdentifier = "multiview.secondaryStrip"
            strip.accessibilityLabel = "Other cameras"
            view.addSubview(strip)
            strip.layer.mask = edgeMask
            edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
            edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        }

        /// One root per slot, in slot order. A slot keeps its host for the controller's life.
        public func update(layout: MultiviewPresentationLayout, roots: [AnyView]) {
            loadViewIfNeeded()
            let resetScroll =
                geometry?.secondaryViewport != layout.secondaryViewport
                || geometry?.secondaryIndices != layout.secondaryIndices
            geometry = layout
            for (index, root) in roots.enumerated() {
                if hosts.indices.contains(index) {
                    hosts[index].rootView = root
                } else {
                    let host = UIHostingController(rootView: root)
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    host.view.clipsToBounds = true
                    addChild(host)
                    view.addSubview(host.view)
                    host.didMove(toParent: self)
                    hosts.append(host)
                }
            }
            while hosts.count > roots.count {
                let host = hosts.removeLast()
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            if resetScroll { strip.setContentOffset(.zero, animated: false) }
            placeHosts()
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            placeHosts()
        }

        private func placeHosts() {
            guard let geometry else { return }
            let viewport = geometry.secondaryViewport.map(Self.rect) ?? .zero
            strip.isHidden = viewport.isEmpty
            strip.frame = viewport
            for (index, host) in hosts.enumerated() where geometry.tiles.indices.contains(index) {
                let secondary = geometry.secondaryIndices.contains(index)
                let parent: UIView = secondary ? strip : view
                if host.view.superview !== parent { parent.addSubview(host.view) }
                let frame = Self.rect(geometry.tiles[index])
                host.view.frame =
                    secondary
                    ? frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY) : frame
            }
            let contentHeight: CGFloat = geometry.secondaryIndices.reduce(0) { height, index in
                max(height, CGFloat(geometry.tiles[index].maxY) - viewport.minY)
            }
            strip.contentSize = CGSize(width: viewport.width, height: contentHeight)
            let offset = max(0, min(strip.contentOffset.y, contentHeight - viewport.height))
            if strip.contentOffset.y != offset {
                strip.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            }
            updateFades()
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFades() }

        private func updateFades() {
            let above = strip.contentOffset.y > 1
            let below = strip.contentOffset.y + strip.bounds.height < strip.contentSize.height - 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // UIScrollView moves its layer bounds while scrolling. Keep the alpha
            // mask in the visible viewport, fading the contents rather than painting
            // an opaque gradient over the picture or panel background.
            edgeMask.frame = strip.bounds
            let edge = min(0.5, 18 / max(1, strip.bounds.height))
            edgeMask.locations = [
                0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1,
            ]
            if previousEdges != [above, below] {
                edgeMask.colors = [
                    (above ? UIColor.clear : .white).cgColor, UIColor.white.cgColor,
                    UIColor.white.cgColor, (below ? UIColor.clear : .white).cgColor,
                ]
                previousEdges = [above, below]
            }
            CATransaction.commit()
        }

        /// Slot `index`'s frame in the stage and the part of it that is visible.
        public func placement(_ index: Int) -> (frame: CGRect, clip: CGRect)? {
            guard hosts.indices.contains(index) else { return nil }
            let host = hosts[index]
            let frame = host.view.convert(host.view.bounds, to: view)
            let clip = host.view.superview === strip ? frame.intersection(strip.frame) : frame
            return clip.isEmpty ? nil : (frame, clip)
        }

        private static func rect(_ rect: MonitorRect) -> CGRect {
            CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }
#endif
