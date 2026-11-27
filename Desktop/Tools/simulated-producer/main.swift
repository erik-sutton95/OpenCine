// SIMULATED. Feeds a moving test picture into one driver slot, to prove inputs with no camera.
// Usage: simulated-producer --slot 2 --seconds 40 [--die-after 10]
import CoreMedia
import CoreVideo
import Foundation
import OpenCineDesktopKit
import OpenCineVirtualCamera

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
        index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let number = argument("--slot").flatMap(Int.init), let slot = VirtualCameraSlot(number: number)
else {
    FileHandle.standardError.write(Data("usage: simulated-producer --slot <1-8> --seconds <n>\n".utf8))
    exit(2)
}
let seconds = argument("--seconds").flatMap(Double.init) ?? 30
let dieAfter = argument("--die-after").flatMap(Double.init)

@MainActor func run() {
    let output = VirtualCameraOutput(slot: slot)
    output.setEnabled(true)
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(
        nil, nil,
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pool)
    let started = Date()
    var tick = 0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        MainActor.assumeIsolated {
            let elapsed = Date().timeIntervalSince(started)
            if let dieAfter, elapsed > dieAfter { exit(9) }
            if elapsed > seconds { exit(0) }
            tick += 1
            var made: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
                let buffer = made
            else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            // Every frame differs across the whole picture, so a coarse receiver hash sees each one.
            let shade = UInt8(40 + (tick * 3 + slot.number * 50) % 180)
            for y in 0..<1080 { memset(bytes + y * row, Int32(shade), 1920 * 4) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            output.submit(buffer, timestamp: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }
}
MainActor.assumeIsolated { run() }
RunLoop.main.run()
