import OpenCineAppKit
import OpenCineCore
import Testing

/// SIMULATED typed power on a stage tile (twin of Kotlin MultiviewTilePowerTest).
struct MultiviewTilePowerTests {
    @Test func aGaugeDrawsBarsAPercentPrintsAndUnknownShowsNeither() {
        let tile = MultiviewTile(name: "SIMULATED", battery: 50, charging: true, batteryBars: 2)
        let gauge = PowerStatus(battery: .init(0.6, origin: .cameraReported, at: nil, precision: .quantized(step: 0.2)))
        let bars = tile.withPower(gauge)
        #expect(bars.battery == nil && bars.batteryBars == 3 && bars.batteryBarCount == 5 && !bars.charging)
        let percent = tile.withPower(PowerStatus(
            battery: .init(0.42, origin: .cameraReported, at: nil, precision: .quantized(step: 0.01)),
            externalPower: .init(true, origin: .cameraReported, at: nil)))
        #expect(percent.battery == 42 && percent.batteryBars == nil && percent.charging,
            "External power reads as charging, as on the live chrome")
        let unknown = tile.withPower(nil)
        #expect(unknown.battery == nil && unknown.batteryBars == nil && !unknown.charging)
    }
}
