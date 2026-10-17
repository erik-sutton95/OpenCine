import Foundation
import OpenCineMedia

/// `camcap_shutter` — legal shutter set the body publishes over `0x00/0x99`.
///
/// Not a `0x02/0x28` GET. SET stays `0x02/0x28`. The table reshapes with fps /
/// rec format / expo (Mimo re-pushes on those changes). Pocket 4 Pro value:
///
/// ```
/// 01 | innerLen:u16-LE | 10 B header | count × 3 B
/// header ends `05 <count>`
/// item = encoded:u16-LE + flag
/// encoded | 0x8000 → 1/N  (same encoding as the shutter SET)
/// encoded without 0x8000 → N seconds (photo); wheel ignores those
/// ```
public enum CamCapShutter {

    /// Pocket 3 rejects `camcap_shutter`. Until a table lands, offer the
    /// documented video ladder so Speed/Angle are not stuck on the live 1/N.
    /// 1/8000, 1/3200, 1/200, 1/100 and 1/50 were accepted or shown in the
    /// Pocket 3 survey; remaining cine stops use the same `0x02/0x28` form.
    public static let emptyCapVideoDenoms: [Int] = [
        8000, 6400, 4000, 3200, 2000, 1600, 1000, 800, 500, 400, 250, 200,
        125, 120, 100, 60, 50, 48, 40, 30, 25, 24,
    ]

    /// Wheel options: camera list when published. Empty-cap uses the documented
    /// video ladder and keeps an unpublished live value visible.
    public static func wheelDenoms(available: [Int], current: Int) -> [Int] {
        if !available.isEmpty { return available }
        return mergeCurrent(current, into: emptyCapVideoDenoms)
    }

    private static func mergeCurrent(_ current: Int, into ladder: [Int]) -> [Int] {
        guard (1...16_000).contains(current), !ladder.contains(current) else {
            return ladder
        }
        var out = ladder
        if let idx = out.firstIndex(where: { $0 < current }) {
            out.insert(current, at: idx)
        } else {
            out.append(current)
        }
        return out
    }

    public static func nearestDenom(_ current: Int, in denoms: [Int]) -> Int? {
        guard !denoms.isEmpty else { return nil }
        return denoms.min(by: { abs($0 - current) < abs($1 - current) })
    }

    /// Next / previous 1/N in camera order. nil at the end.
    public static func steppedDenom(from current: Int, steps: Int, available: [Int]) -> Int? {
        let list = wheelDenoms(available: available, current: current)
        let idx =
            list.firstIndex(of: current)
            ?? list.firstIndex(of: nearestDenom(current, in: list) ?? -1)
        guard let idx else { return nil }
        let next = idx + steps
        guard list.indices.contains(next), next != idx else { return nil }
        return list[next]
    }

    public static func label(_ denom: Int) -> String { "1/\(denom)" }

    public static func denom(from label: String) -> Int? {
        Int(label.replacingOccurrences(of: "1/", with: ""))
    }

}

/// `camcap_iso` — legal ISO indices for the current color / mode.
///
/// ```
/// 01 | innerLen:u16-LE | 00 | count:u8 | count × index
/// ```
/// D-Log2 example: `01 08 00 00 06 03 04 05 06 07 08` → 100…3200.
public enum CamCapIso {

    public static func wheelIndices(available: [IsoIndex], fallback: [IsoIndex]) -> [IsoIndex] {
        available.isEmpty ? fallback : available
    }

    /// Native base ISO for the operator's current transfer. Decoration only —
    /// the wheel list stays `camcap_iso`.
    ///
    /// D-Log = 400, D-Log2 = 1600. Rec.709 / HLG have no published Pocket
    /// native base (OpenZCine stars Nikon 800/6400; do not invent a third).
    /// Uses `CameraStatus.monitorTransfer` (`colorMode` `@2`), not a tele hop SET.
    public static func baseISO(transfer: MonitorTransfer?) -> Int? {
        switch transfer {
        case .dlog: 400
        case .dlog2: 1600
        case .rec709, .hdr, .dlogm, .ilog, .srgb, .nlog, .log3G10, nil: nil
        }
    }

    public static func baseISO(colorMode: ColorMode?) -> Int? {
        switch colorMode {
        case .dLog: 400
        case .dLog2: 1600
        default: nil
        }
    }

    public static func markedLabels(transfer: MonitorTransfer?) -> Set<String> {
        guard let iso = baseISO(transfer: transfer) else { return [] }
        return ["\(iso)"]
    }

    public static func markedLabels(colorMode: ColorMode?) -> Set<String> {
        markedLabels(transfer: colorMode.map(MonitorTransfer.init))
    }

    /// If the operator is still on `from`'s native ISO, hop to `to`'s native.
    /// Off-base or Auto stays put. Rec.709 / HDR have no native — no hop.
    /// `hopEnabled` is the ISO-sheet Native ISO toggle (default on).
    public static func nativeISOHop(
        from: ColorMode?, to: ColorMode, current: IsoIndex?,
        hopEnabled: Bool = true
    ) -> IsoIndex? {
        guard hopEnabled else { return nil }
        guard let from, from != to else { return nil }
        guard let fromBase = baseISO(colorMode: from),
            let toBase = baseISO(colorMode: to)
        else { return nil }
        guard let current, current != .auto, current.isoValue == fromBase else { return nil }
        return to.isoIndices.first { $0.isoValue == toBase }
    }
}

/// Nano `camcap_color_mode` (Mimo 2026-08-18): `01 04 00 03 00 3F 3D`.
/// Wire (with the body model): `00` Normal 8-bit / `3F` Normal 10-bit /
/// `3D` D-Log M. Pocket 3 `@2` / SET bytes are `00`/`3C`/`3D` (#176).
public enum CamCapColorMode {

    public static func wheel(available: [ColorMode], model: CameraModel) -> [ColorMode] {
        wheel(available: available, order: model.captureProfile?.labels.colorModes ?? [])
    }

    /// Body order is the legal set. `camcap_color_mode` may subset it.
    /// It cannot add D-Log2 (or `0x17` D-Log) to a body that does not have them.
    public static func wheel(available: [ColorMode], order: [ColorMode]) -> [ColorMode] {
        guard !order.isEmpty else { return available }
        guard !available.isEmpty else { return order }
        let have = Set(available)
        let ranked = order.filter { have.contains($0) }
        return ranked.isEmpty ? order : ranked
    }

    /// The colour drum: the `offered` modes, plus the camera's reported `current` mode when the
    /// offered list lacks it, so the popup opens centred on the value the header shows. That
    /// extra entry is shown, never sent: a SET goes only to an offered mode.
    /// Kotlin twin: `CaptureWheels.colorDrum`.
    public static func drum(offered: [ColorMode], current: ColorMode?) -> [ColorMode] {
        guard let current, !offered.contains(current) else { return offered }
        return offered + [current]
    }
}

/// `camcap_video_format` — legal `[res][fps]` pairs for the current shooting mode.
///
/// Mimo live-start 2026-08-28 (Pocket 4 Pro, Video):
/// `01 25 00 0c` then 12× `[res][fps_idx] 00` — 4K 24–60 then 1080p 60–24.
/// Slow-mo 100/120/240 is a different shooting mode; this table is Video only.
public enum CamCapVideoFormat {

    /// Pocket 3 rejects camcap subscriptions. Documented mode tables fill the picker
    /// only when the body reported nothing. Reported capabilities always win.
    /// Pocket 4 / 4 Pro / Nano get no invented tables. TimeLapse / HyperLapse
    /// format menus were UI-only in the Pocket 3 survey — no accepted `0x02/0x18`
    /// pairs — so they stay empty until camcap or a later accepted capture.
    /// Pocket 3 Video 9:16 is body Lock Portrait; the survey never accepted a
    /// portrait `0x02/0x18` SET, so the fallback does not offer 9:16.
    public static func pickerFormats(
        available: [VideoFormat], model: CameraModel?, shootingMode: Int
    ) -> [VideoFormat] {
        if !available.isEmpty { return available }
        guard let mode = ShootingMode.fromStatus(shootingMode) else { return [] }
        return model?.captureProfile?.videoFormatFallbacks[mode] ?? []
    }

    /// Operator FORMAT SET. Empty tables are read-only (current pair only).
    /// Documented Pocket 3 fallbacks fill `pickerFormats`; Pocket 4 / 4 Pro never invent.
    public static func allowsOperatorSet(
        _ format: VideoFormat,
        available: [VideoFormat],
        model: CameraModel?,
        shootingMode: Int
    ) -> Bool {
        let legal = pickerFormats(
            available: available, model: model, shootingMode: shootingMode)
        return !legal.isEmpty && legal.contains(format)
    }

    public static func resolutions(
        available: [VideoFormat], current: VideoResolution?
    ) -> [VideoResolution] {
        resolutions(available: available, aspect: nil, current: current)
    }

    public static func resolutions(
        available: [VideoFormat], aspect: VideoAspect?, current: VideoResolution?
    ) -> [VideoResolution] {
        if available.isEmpty {
            // Read-only current pair. Do not offer 1080/4K tabs that would SET
            // a different resolution at the live fps (1080 240 → 4K 240).
            guard let current, aspect == nil || current.aspect == aspect else { return [] }
            return [current]
        }
        var seen = Set<VideoResolution>()
        var out: [VideoResolution] = []
        for format in available {
            if let aspect, format.resolution.aspect != aspect { continue }
            if seen.insert(format.resolution).inserted {
                out.append(format.resolution)
            }
        }
        if let current, !seen.contains(current), aspect == nil || current.aspect == aspect {
            out.insert(current, at: 0)
        }
        return out
    }

    public static func aspects(
        available: [VideoFormat], current: VideoAspect?
    ) -> [VideoAspect] {
        if available.isEmpty {
            return current.map { [$0] } ?? []
        }
        var seen = Set<VideoAspect>()
        var out: [VideoAspect] = []
        for format in available {
            guard let aspect = format.resolution.aspect else { continue }
            if seen.insert(aspect).inserted { out.append(aspect) }
        }
        if let current, !seen.contains(current) {
            out.insert(current, at: 0)
        }
        return out
    }

    public static func frameRates(
        available: [VideoFormat], resolution: VideoResolution, current: VideoFrameRate?
    ) -> [VideoFrameRate] {
        let rates = available.filter { $0.resolution == resolution }.map(\.frameRate)
        if rates.isEmpty {
            // Read-only live rate. Do not offer 24–60 (or any other size) until
            // camcap or a documented Pocket 3 fallback fills the table.
            return current.map { [$0] } ?? []
        }
        return rates
    }
}
