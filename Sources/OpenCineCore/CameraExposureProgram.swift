import Foundation

/// A reported exposure program, independent of pending ISO/shutter targets or UI routing.
public enum CameraExposureProgram: String, Hashable, Codable, Sendable, CaseIterable {
    case automatic, manual, isoPriority, shutterPriority, aperturePriority, program
}
