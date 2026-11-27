// Reports what a receiving app would get from one virtual camera input. Selects only the exact
// device named on the command line, never a physical camera. Writes no media.
//
// Build: swiftc -O -o virtual-receiver main.swift
// Usage: virtual-receiver --uid OpenCine.Camera.1 --seconds 30 [--save-frame /path/frame.png]
import AVFoundation
import CoreImage
import Foundation

struct Report: Encodable {
    var frames = 0
    var uniqueFrames = 0
    var slateFrames = 0
    var maxGapMs = 0
    var width = 0
    var height = 0
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
        index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

final class Receiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var report = Report()
    var savePath: String?
    private var previousHash: UInt64?
    private var previousTime: UInt64?

    /// An FNV hash of a sparse pixel grid: enough to tell repeated frames from changed ones.
    private func sample(_ buffer: CVPixelBuffer) -> (hash: UInt64, flat: Bool) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, true) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var hash: UInt64 = 14_695_981_039_346_656_037
        var minimum = 255
        var maximum = 0
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                for channel in 0..<3 {
                    let value = bytes[y * row + x * 4 + channel]
                    hash = (hash ^ UInt64(value)) &* 1_099_511_628_211
                    minimum = min(minimum, Int(value))
                    maximum = max(maximum, Int(value))
                }
            }
        }
        return (hash, maximum - minimum < 48)
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        report.frames += 1
        report.width = CVPixelBufferGetWidth(buffer)
        report.height = CVPixelBufferGetHeight(buffer)
        let now = DispatchTime.now().uptimeNanoseconds
        if let previousTime {
            report.maxGapMs = max(report.maxGapMs, Int((now - previousTime) / 1_000_000))
        }
        previousTime = now
        let (hash, flat) = sample(buffer)
        if flat { report.slateFrames += 1 }
        if hash != previousHash {
            report.uniqueFrames += 1
            previousHash = hash
        }
        // Two seconds in, past the slate a stream can open on before its first picture.
        if report.frames >= 60, let path = savePath {
            savePath = nil
            let image = CIImage(cvPixelBuffer: buffer)
            try? CIContext().writePNGRepresentation(
                of: image, to: URL(fileURLWithPath: path), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}

guard let uid = argument("--uid") else {
    FileHandle.standardError.write(Data("usage: virtual-receiver --uid <id> --seconds <n>\n".utf8))
    exit(2)
}
let seconds = Double(argument("--seconds") ?? "10") ?? 10
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external], mediaType: .video, position: .unspecified)
guard let device = discovery.devices.first(where: { $0.uniqueID == uid || $0.localizedName == uid })
else {
    let found = discovery.devices.map { "\($0.localizedName) [\($0.uniqueID)]" }
    FileHandle.standardError.write(Data("device not found; have: \(found)\n".utf8))
    exit(1)
}
let session = AVCaptureSession()
let receiver = Receiver()
receiver.savePath = argument("--save-frame")
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
output.setSampleBufferDelegate(receiver, queue: DispatchQueue(label: "virtual-receiver"))
do {
    session.addInput(try AVCaptureDeviceInput(device: device))
} catch {
    FileHandle.standardError.write(Data("cannot open \(uid): \(error)\n".utf8))
    exit(1)
}
session.addOutput(output)
session.startRunning()
Thread.sleep(forTimeInterval: seconds)
session.stopRunning()
let encoder = JSONEncoder()
print(String(data: try encoder.encode(receiver.report), encoding: .utf8)!)
