import Insta360Protocol
import OpenCineCore

/// Keeps a camera on a Wi-Fi or hotspot setup's network: firmware v1.2.7 leaves the network about
/// 60 s after each join, so while the control link is open the join is sent again at once and then
/// every `LunaProtocol.stationKeepAliveInterval` (`LunaProtocol.stationKeepAliveRequest`). A failed
/// send is logged and the next one tried on time; the control link's own checks end the connection.
/// The log never shows the password.
@MainActor
struct LunaStationKeepAlive {
    /// Sends one request over the control link on the setup's network.
    var send: @MainActor (LunaRequest) async throws -> Void
    var clock: HostClock
    /// False once the connection this keep-alive belongs to is gone.
    var isCurrent: @MainActor () -> Bool
    var log: @MainActor (String) -> Void
    var interval: Duration = LunaProtocol.stationKeepAliveInterval

    /// Runs until cancelled or no longer current.
    func run(_ network: LunaStationNetwork) async {
        guard
            let request = try? LunaProtocol.stationKeepAliveRequest(
                ssid: network.ssid, password: network.password)
        else { return }
        var failures = 0
        while !Task.isCancelled, isCurrent() {
            do {
                try await send(request)
                if failures > 0 { log("luna: station keep-alive answered again") }
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isCurrent() else { return }
                failures += 1
                log("luna: station keep-alive not answered (\(failures) in a row)")
            }
            do { try await clock.sleep(interval) } catch { return }
        }
    }
}
