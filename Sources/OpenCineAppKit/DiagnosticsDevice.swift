import Foundation

/// The phone as every diagnostic names it: one hardware class, OS name and version for incident
/// sessions, problem reports and the diagnostics export, computed here once instead of in each app
/// (A6-13). Kotlin twin: `appkit/diagnostics/DiagnosticsDevice.kt`.
public struct DiagnosticsDevice: Equatable, Sendable {
    /// The machine identifier, for example `iPhone17,2`; a simulator names the device it models.
    public var hardwareClass: String
    public var osName: String
    /// `major.minor[.patch]`, as `UIDevice.systemVersion` prints it.
    public var osVersion: String

    public init(hardwareClass: String, osName: String, osVersion: String) {
        self.hardwareClass = hardwareClass
        self.osName = osName
        self.osVersion = osVersion
    }

    public static let current = DiagnosticsDevice(
        hardwareClass: machineIdentifier(environment: ProcessInfo.processInfo.environment),
        osName: platformName,
        osVersion: version(ProcessInfo.processInfo.operatingSystemVersion))

    /// `uname` machine; the simulator's own (`arm64`) yields to the device it models.
    public static func machineIdentifier(environment: [String: String]) -> String {
        if let modelled = environment["SIMULATOR_MODEL_IDENTIFIER"], !modelled.isEmpty {
            return modelled
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "unknown" : machine
    }

    public static func version(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    private static var platformName: String {
        #if os(iOS)
            "iOS"
        #elseif os(watchOS)
            "watchOS"
        #elseif os(macOS)
            "macOS"
        #else
            "unknown"
        #endif
    }
}
