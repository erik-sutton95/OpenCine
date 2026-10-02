import Foundation
import OpenCineNikon

/// Validated live-view request resolved by the shared Swift policy for the Android shell.
public struct AndroidLiveViewRequest: Equatable, Sendable {
    /// Camera JPEG preview size (`1` QVGA, `2` VGA, `3` XGA).
    public let imageSize: UInt8
    /// Camera JPEG preview compression selector.
    public let compression: UInt8
    /// Minimum interval between Android preview pulls, in monotonic nanoseconds.
    public let frameIntervalNanoseconds: UInt64

    /// Creates a Swift-owned preview request.
    public init(imageSize: UInt8, compression: UInt8, frameIntervalNanoseconds: UInt64) {
        self.imageSize = imageSize
        self.compression = compression
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
    }
}

/// Coarse Android JNI wire for shared live-view stream policy.
///
/// Kotlin supplies only its persisted choice and host thermal observation.
/// The app's facade resolves the Nikon byte values (its `resolve` extension, which reads the
/// app's operator preferences) and applies ``LiveViewLoadPolicy`` in Swift, keeping camera
/// protocol policy out of Compose. The result controls only a disposable preview stream; it never
/// changes the camera's recording configuration.
///
/// Preview pull cadence is **always** ``targetFrameRate`` (60 Hz). Thermal
/// shedding may still drop preview JPEG size; it never slows the pull target.
public enum AndroidLiveViewPolicyWire {
    /// Fixed monitor pull rate (always).
    public static let targetFrameRate = 60

    /// Preview pull interval for ``targetFrameRate`` (~16.7 ms at 60 Hz).
    public static let minimumFrameIntervalNanoseconds: UInt64 =
        1_000_000_000 / UInt64(targetFrameRate)

    /// Slowest accepted configure interval (validation only; policy never emits this).
    public static let maximumFrameIntervalNanoseconds: UInt64 = 100_000_000

    /// Always equal to the 60 Hz target interval.
    public static let standardFrameIntervalNanoseconds: UInt64 =
        minimumFrameIntervalNanoseconds

    /// Encodes the safe request as `size<TAB>compression<TAB>intervalNanos` for JNI.
    public static func encode(_ request: AndroidLiveViewRequest) -> String {
        "\(request.imageSize)\t\(request.compression)\t\(request.frameIntervalNanoseconds)"
    }
}
