#if os(iOS)
    import Foundation
    import OpenCineDJI

    extension DjiAppleControlEndpoint {
        /// Uses the actual native write queue. Queued sequence is separate from eventual write/ACK.
        public init(bluetooth: DjiAppleBluetoothLink? = nil, datalink: DjiAppleDatalink?) {
            self.init(
                writeBLE: { [weak bluetooth] in bluetooth?.send($0) },
                writeDatalink: { [weak datalink] frame in
                    guard let datalink else { return .skipped }
                    let sequence = datalink.send(frame)
                    return datalink.lastWriteLanded == false ? .skipped : .queued(sequence)
                },
                writeAdmittedDatalink: { [weak datalink] frame, admission in
                    datalink?.send(frame, admission: admission) ?? .skipped
                })
        }
    }
#endif
