#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import QuartzCore
import UIKit

/// One native picture tree; retiring hosts cannot resize or disable a layer adopted elsewhere.
open class MonitorVideoPictureContainer: UIView {
    public let displayLayer: AVSampleBufferDisplayLayer
    private let pictureHost = UIView()
    private var pictureMirrored = false
    private var pictureFlippedVertically = false
    public let processedPicture: MonitorPictureHost
    public var onReady: (() -> Void)?

    /// A replacement host can adopt the session's layer before this view retires.
    /// Late updates and layout from the old host must not change the live owner.
    public var ownsDisplayLayer: Bool { displayLayer.superlayer === pictureHost.layer }

    public init(_ layer: AVSampleBufferDisplayLayer, processedPicture: MonitorPictureHost) {
        displayLayer = layer
        self.processedPicture = processedPicture
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.videoGravity = .resizeAspect
        addSubview(pictureHost)
        pictureHost.isUserInteractionEnabled = false
        pictureHost.backgroundColor = .black
        pictureHost.layer.addSublayer(layer)
        pictureHost.addSubview(processedPicture)
        processedPicture.isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func setPictureMirrored(_ mirrored: Bool) {
        pictureMirrored = mirrored
        applyPictureTransform()
    }

    public func setPictureFlippedVertically(_ flipped: Bool) {
        guard flipped != pictureFlippedVertically else { return }
        pictureFlippedVertically = flipped
        applyPictureTransform()
    }

    private func applyPictureTransform() {
        let scale = CGSize(width: pictureMirrored ? -1 : 1,
            height: pictureFlippedVertically ? -1 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureHost.transform = CGAffineTransform(scaleX: scale.width, y: scale.height)
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        processedPicture.isEnabled = ownsDisplayLayer && window != nil
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard ownsDisplayLayer else {
            processedPicture.isEnabled = false
            return
        }
        // UIKit can resize the overlay immediately while the standalone video
        // layer implicitly interpolates its bounds. Commit both as one geometry
        // update; any enclosing rotation animation then moves the complete picture.
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [pictureHost.layer, displayLayer, processedPicture.layer] {
                layer.removeAnimation(forKey: "bounds")
                layer.removeAnimation(forKey: "position")
            }
            pictureHost.bounds = CGRect(origin: .zero, size: bounds.size)
            pictureHost.center = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.frame = pictureHost.bounds
            processedPicture.frame = pictureHost.bounds
            processedPicture.layoutIfNeeded()
            applyPictureTransform()
            CATransaction.commit()
        }
        processedPicture.isEnabled = window != nil && bounds.width > 1 && bounds.height > 1
        if bounds.width > 1, bounds.height > 1 { onReady?() }
    }
}

#endif
