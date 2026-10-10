#if os(watchOS)
import OpenCineRelay
import UIKit

public typealias WatchSessionController = WatchReceiver<WatchRelayCodec>

extension WatchReceiver where Codec == WatchRelayCodec {
    public convenience init() {
        #if targetEnvironment(simulator)
        self.init(codec: WatchRelayCodec(), acceptsContext: true, simulatorImage: Self.simulatedFrame)
        #else
        self.init(codec: WatchRelayCodec(), acceptsContext: true)
        #endif
    }
    #if targetEnvironment(simulator)
    private static var simulatedFrame: UIImage? {
        let size = CGSize(width: 320, height: 180)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(colorsSpace: space, colors: [
                CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                CGColor(srgbRed: 0.18, green: 0.42, blue: 0.55, alpha: 1),
            ] as CFArray, locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero,
            end: CGPoint(x: size.width, y: size.height), options: [])
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
    #endif
}
#endif
