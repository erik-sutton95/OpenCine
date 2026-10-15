import OpenCineMedia

public typealias StorageReadout = OpenCineMedia.StorageReadout

extension CameraStatus {
    /// The one volume-selection rule for the DJI-wire status, whose storage fields are MiB (as
    /// DJI reports them and the Luna mapping publishes them): the aggregate store when it reports,
    /// else the SD card; nil when neither reports anything.
    public var storageReadout: StorageReadout? {
        let aggregate = storageTotalMb > 0 || storageFreeMb > 0
        let free = aggregate ? storageFreeMb : sdFreeMb
        let total = aggregate ? storageTotalMb : sdTotalMb
        guard free >= 0, free > 0 || total > 0, total <= 0 || free <= total else { return nil }
        return StorageReadout(
            freeBytes: UInt64(free) * 1_048_576,
            totalBytes: total > 0 ? UInt64(total) * 1_048_576 : nil)
    }

    /// The wrist's media slot: the readout with its percentage, else the camera's remaining
    /// minutes, else the free size alone.
    public var wristMediaLabel: String {
        if let readout = storageReadout, readout.totalBytes != nil { return readout.label }
        if recordRemainingSec > 0 { return "\(recordRemainingSec / 60) Min" }
        return storageReadout?.label ?? StorageReadout.unavailable
    }
}
