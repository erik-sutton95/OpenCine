#if os(iOS)
import Foundation

extension DjiAppleHeartbeatEndpoint {
    /// Keeps the actual datalink's registration/ACK and readiness guards in their native owner.
    public init(bluetooth: DjiAppleBluetoothLink? = nil, datalink: DjiAppleDatalink?) {
        self.init(writeBLE: { [weak bluetooth] in bluetooth?.send($0) },
            registerDatalink: { [weak datalink] in datalink?.keepalive() },
            transport: { [weak datalink] in
                .init(lastVideoAt: datalink?.lastVideoPacketAt?.timeIntervalSinceReferenceDate,
                    lastSelfieFlipReplyAt: datalink?.lastSelfieFlipReplyAt?.timeIntervalSinceReferenceDate,
                    lastSelfieFlipSendAt: datalink?.lastSelfieFlipSendAt?.timeIntervalSinceReferenceDate,
                    rebuilding: datalink?.isRebuilding == true)
            })
    }
}
#endif
