#if os(iOS)
import Foundation
import OpenCineGyro
import OpenCineGyroApple
import Testing

@Suite struct PhoneMotionDriverTests {
    @Test func bufferRetainsAtMost512SamplesThenReportsOverflow() {
        let buffer = GyroSampleBuffer()
        for index in 0..<600 {
            buffer.append(GyroSample(timestamp: Double(index) / 100, x: 1, y: 2, z: 3))
        }
        let batch = buffer.drain()
        #expect(batch.samples.count == 512)
        #expect(batch.failure == .bufferOverflow)
        #expect(buffer.drain().samples.isEmpty)
    }

    @Test func gyroHandlerRunsOffTheMainActor() async {
        let buffer = GyroSampleBuffer()
        let handler = PhoneMotionDriver.gyroHandler(into: buffer)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let ranOnMainThread = await withCheckedContinuation { continuation in
            queue.addOperation {
                handler(nil, nil)
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        #expect(!ranOnMainThread)
        let result = buffer.drain()
        #expect(result.samples.isEmpty)
        #expect(result.failure == .sensorStalled)
    }

    @Test func motionReadingUsesGravityAndTotalAcceleration() {
        let reading = PhoneMotionDriver.reading(
            gravity: (0, 0, -1),
            userAcceleration: (0, 0, -0.1),
            rotationRate: (0, 0.6, 0.8),
            timestamp: 12.5)
        #expect(reading.phoneDown == GyroVector3(x: 0, y: 0, z: -1))
        #expect(abs(reading.rotationRate - 1) < 1e-12)
        #expect(abs(reading.accelerationG - 1.1) < 1e-12)
        #expect(reading.timestamp == 12.5)
    }
}
#endif
