import Foundation
import OpenCineCameraVocabulary

/// The result of one descriptor observation, independent of effective write authorization.
public enum NikonDescriptorReadOutcome: String, Equatable, Sendable {
    case unknown, notAttempted, pending, described, missing, unsupported, rejected, malformed
    case transportFailed, mediaBusy
}

/// Where the existing effective option list came from; fallback is never camera advertisement.
public enum NikonDescriptorOptionOrigin: String, Equatable, Sendable {
    case unknown, descriptor, legacyFallback
}

/// Nikon-owned source facts from one describe attempt. Raw protocol metadata stays in Nikon.
public struct NikonDescriptorObservation: Equatable, Sendable {
    public let outcome: NikonDescriptorReadOutcome
    public let descriptor: NikonScalarPropertyDescriptor?
    public let operation: PTPOperationCode?
    public let response: UInt16?

    public init(
        outcome: NikonDescriptorReadOutcome, descriptor: NikonScalarPropertyDescriptor? = nil,
        operation: PTPOperationCode? = nil, response: UInt16? = nil
    ) {
        self.outcome = outcome
        self.descriptor = descriptor
        self.operation = operation
        self.response = response
    }

    /// Only parsed descriptor metadata or an explicit unsupported result establishes support.
    /// Empty and unrecognized enumerations remain supported observations with an empty offer.
    public var capability: ControlCapability<[String]> {
        guard outcome == .described, let descriptor else {
            return outcome == .unsupported ? .unsupported : .unknown
        }
        var choices: [String]?
        if case .enumeration(let values) = descriptor.form,
            let property = PTPPropertyCode(rawValue: descriptor.property)
        {
            let raw = values.map { bytes in
                bytes.enumerated().reduce(UInt32(0)) { value, item in
                    item.offset < 4 ? value | UInt32(item.element) << (item.offset * 8) : value
                }
            }
            if property == .electronicVR {
                choices = raw.filter { $0 <= 1 }.map {
                    PTPCameraPropertyDecoders.onOffLabel(UInt8($0))
                }
            } else {
                choices = PTPCameraPropertyDecoders.optionLabels(for: property, rawValues: raw)
            }
        }
        return .supported(choices, access: descriptor.writable ? .readWrite : .readOnly)
    }

    /// Completed non-OK response, preserving the actual operation and raw response code.
    public static func rejected(operation: PTPOperationCode, response: UInt16) -> Self {
        // A describe refusal, including DevicePropNotSupported, does not establish whether
        // the setting itself can operate under the existing legacy authorization.
        .init(
            outcome: .rejected,
            operation: operation, response: response)
    }
}

/// Retained evidence and the latest attempt are separate across a transient refresh failure.
/// This record does not authorize writes or replace the existing effective options.
public struct NikonDescriptorEvidence: Equatable, Sendable {
    public var observation: NikonDescriptorObservation
    public var latestAttempt: NikonDescriptorObservation
    public var optionOrigin: NikonDescriptorOptionOrigin
    /// Most recent actually parsed descriptor for this owner/property, including aborted generations.
    /// This is separate from the catalog's retained observation and the latest failed/skipped attempt.
    public var lastValidObservation: NikonDescriptorObservation?

    public init(
        observation: NikonDescriptorObservation = .init(outcome: .notAttempted),
        latestAttempt: NikonDescriptorObservation? = nil,
        optionOrigin: NikonDescriptorOptionOrigin = .unknown,
        lastValidObservation: NikonDescriptorObservation? = nil
    ) {
        self.observation = observation
        self.latestAttempt = latestAttempt ?? observation
        self.optionOrigin = optionOrigin
        let latest = latestAttempt ?? observation
        let valid = latest.outcome == .described && latest.descriptor != nil ? latest : observation
        self.lastValidObservation =
            lastValidObservation
            ?? (valid.outcome == .described && valid.descriptor != nil ? valid : nil)
    }

    /// A failed or pending read never relabels retained descriptor evidence as a fresh success.
    public mutating func record(_ attempt: NikonDescriptorObservation) {
        latestAttempt = attempt
        if attempt.outcome == .described, attempt.descriptor != nil {
            lastValidObservation = attempt
        }
        switch attempt.outcome {
        case .pending, .notAttempted, .transportFailed, .mediaBusy: break
        case .rejected, .malformed, .missing:
            if observation.descriptor == nil { observation = attempt }
        default: observation = attempt
        }
    }
}
