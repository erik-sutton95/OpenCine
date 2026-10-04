#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation

    /// Inspects top-level movie atoms and the available payload of an incomplete movie.
    public enum MonitorMovieFile {
        /// True when the file has a finished QuickTime/`moov` header, not just an open `mdat`.
        public static func movieHasFinishedHeader(at url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let fileSize = (try? handle.seekToEnd()) ?? 0
            var offset: UInt64 = 0
            while offset + 8 <= fileSize {
                try? handle.seek(toOffset: offset)
                guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                    let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
                else { return false }
                var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
                if atomSize == 1 {
                    guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else {
                        return false
                    }
                    atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
                if type == "moov" { return true }
                if atomSize < 8 || atomSize == 0 { return false }
                offset += atomSize
            }
            return false
        }

        /// True when an `mdat` atom's declared size runs past EOF - Partial sources (and partial
        /// caches) can ship a complete `moov` for more media than the file actually contains.
        public static func mediaDataExtendsPastEndOfFile(at url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let fileSize = (try? handle.seekToEnd()) ?? 0
            var offset: UInt64 = 0
            while offset + 8 <= fileSize {
                try? handle.seek(toOffset: offset)
                guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                    let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
                else { return false }
                var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
                if atomSize == 1 {
                    guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else {
                        return false
                    }
                    atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
                if type == "mdat", atomSize >= 8, offset + atomSize > fileSize {
                    return true
                }
                if atomSize < 8 { return false }
                offset += atomSize
            }
            return false
        }

        /// Header duration scaled by how much of `mdat` is actually on disk.
        ///
        /// Sources can advertise a full clip duration while the file was cut off halfway
        /// through media data. Progress uses this so the bar isn't stuck at ~50% of a lying header.
        public static func scaledProgressDuration(for url: URL, headerDuration: CMTime) -> CMTime {
            guard headerDuration.isNumeric, headerDuration.seconds > 0,
                let fraction = mdatAvailableFraction(at: url), fraction > 0, fraction < 0.98
            else { return headerDuration }
            return CMTimeMultiplyByFloat64(headerDuration, multiplier: fraction)
        }

        /// Available `mdat` payload / declared payload when the atom runs past EOF; otherwise `nil`.
        public static func mdatAvailableFraction(at url: URL) -> Double? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let fileSize = (try? handle.seekToEnd()) ?? 0
            var offset: UInt64 = 0
            while offset + 8 <= fileSize {
                try? handle.seek(toOffset: offset)
                guard let sizeBytes = try? handle.read(upToCount: 4), sizeBytes.count == 4,
                    let typeBytes = try? handle.read(upToCount: 4), typeBytes.count == 4
                else { return nil }
                var atomSize = sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
                var header: UInt64 = 8
                if atomSize == 1 {
                    guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else {
                        return nil
                    }
                    atomSize = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    header = 16
                }
                if type == "mdat", atomSize >= header, offset + atomSize > fileSize {
                    let declaredPayload = atomSize - header
                    let available = fileSize - (offset + header)
                    guard declaredPayload > 0 else { return nil }
                    return Double(available) / Double(declaredPayload)
                }
                if atomSize < 8 { return nil }
                offset += atomSize
            }
            return nil
        }

    }
#endif
