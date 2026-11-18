#if canImport(VideoToolbox)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineCore
import OpenCineStreaming

enum MediaFixtures {
    static let format720 = StreamOutputFormat.resolve(
        selected: StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(30, 1)), connected: [],
        preset: .custom)

    /// A BGRA buffer filled by `color(x, y)` as (b, g, r).
    static func picture(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let (b, g, r) = color(x, y)
                let p = base + y * row + x * 4
                p[0] = b
                p[1] = g
                p[2] = r
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    static func solid(width: Int, height: Int, _ bgr: (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        picture(width: width, height: height) { _, _ in bgr }
    }

    /// The (b, g, r) of one pixel of a BGRA buffer.
    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// Stereo float PCM at 48 kHz: a sine of `frames` samples.
    static func tone(frames: Int, rate: Double = 48_000, channels: AVAudioChannelCount = 2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<frames { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.5) }
        }
        return buffer
    }
}

/// Collects encoder output from any thread.
final class PacketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamMediaPacket] = []
    var packets: [StreamMediaPacket] { lock.withLock { stored } }
    var add: @Sendable ([StreamMediaPacket]) -> Void { { [self] new in lock.withLock { stored += new } } }
}
#endif
