#if canImport(UIKit) && canImport(CoreImage) && canImport(VideoToolbox)
    import Foundation
    import OpenCineMedia

    extension MonitorLiveVideoRuntime {
        /// Read-only diagnostic projection. Does not admit samples, change effects or rebuild decoding.
        public func incidentDecoder(wall: Date = Date()) -> FeedIncidentDecoder {
            let decode = incidentDecodeSnapshot
            let failed = isDecoderWedged
            return FeedIncidentDecoder(
                generation: sourceFrameGeneration,
                formatGeneration: vtRebuildCount, codec: incidentCodec,
                width: Int(pictureSize.width), height: Int(pictureSize.height),
                lastStatus: lastDecodeStatus, lastFlags: lastDecodeFlags,
                origin: lastDecodeOrigin == "submit"
                    ? .sync
                    : FeedDecoderErrorOrigin(rawValue: lastDecodeOrigin) ?? .none,
                errorClass: failed ? "nativeDecoder" : nil,
                errorCall: FeedIncidentExport.appleDecoderCall(origin: lastDecodeOrigin),
                errorCount: decoderErrors,
                decoderFailed: failed,
                errorAge: FeedIncidentRateSampler.age(since: lastDecodeErrorAt, now: wall),
                receivedIrap: sawKeyframe, awaitingIrap: awaitingIDR,
                hasDecodableReferences: canReleaseIDRHold,
                lastIrapAge: FeedIncidentRateSampler.age(since: lastIrapAt, now: wall),
                lastSuccessfulOutputAge: decode.outputAge, firstError: firstDecodeError)
        }
    }
#endif
