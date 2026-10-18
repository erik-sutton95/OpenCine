#if os(iOS)
  import CoreText
  import SwiftUI
  import UIKit

  public struct MonitorPortraitPrimaryFit: Equatable, Sendable {
    public let clockSize: CGFloat
    public let primarySize: CGFloat
    public let spacing: CGFloat
    public let completeSingleRow: Bool
    public let detailSize: CGFloat
    public let recordingPadding: CGFloat
    public let recordingSpacing: CGFloat
    public let tracking: CGFloat

    public init(
      clockSize: CGFloat, primarySize: CGFloat, spacing: CGFloat,
      completeSingleRow: Bool, detailSize: CGFloat = 11,
      recordingPadding: CGFloat = 8, recordingSpacing: CGFloat = 5, tracking: CGFloat = 0
    ) {
      self.clockSize = clockSize
      self.primarySize = primarySize
      self.spacing = spacing
      self.completeSingleRow = completeSingleRow
      self.detailSize = detailSize
      self.recordingPadding = recordingPadding
      self.recordingSpacing = recordingSpacing
      self.tracking = tracking
    }
  }

  private struct MonitorPortraitPrimaryFitKey: EnvironmentKey {
    static let defaultValue: MonitorPortraitPrimaryFit? = nil
  }

  extension EnvironmentValues {
    public var monitorPortraitPrimaryFit: MonitorPortraitPrimaryFit? {
      get { self[MonitorPortraitPrimaryFitKey.self] }
      set { self[MonitorPortraitPrimaryFitKey.self] = newValue }
    }
  }

  /// Only measurement normalizes tabular digits. Rendered and accessible values stay complete.
  private func portraitClockShape(_ value: String) -> String {
    String(value.map { "0123456789".contains($0) ? Character("0") : $0 })
  }

  /// One cached fit per mounted deck. Frame digits do not cause repeated font measurement.
  @MainActor public final class MonitorPortraitPrimarySizer {
    private struct Key: Equatable {
      let width: CGFloat
      let scale: CGFloat
      let typeSize: DynamicTypeSize
      let recording: [String]
      let clock: String?
      let primary: String
      let primaryIsDetail: Bool
      let details: [String]
      let color: String?
      let inline: Bool
      let caption: String?
      let maximumSize: CGFloat
      let maximumPrimarySize: CGFloat
      let maximumDetailSize: CGFloat
    }
    private var cached: (key: Key, fit: MonitorPortraitPrimaryFit)?
    public init() {}

    public func fit(
      width: CGFloat, scale: CGFloat, typeSize: DynamicTypeSize,
      recording: [String], clock: String?, primary: String, details: [String]
    ) -> MonitorPortraitPrimaryFit {
      fit(
        width: width, scale: scale, typeSize: typeSize, recording: recording,
        clock: clock, primary: primary, details: details, inline: false, caption: nil,
        maximumSize: 23, color: nil, primaryIsDetail: false)
    }

    /// The portrait status row reserves STBY/REC, the clock and the stacked format group
    /// (primary above, codec, color and caption below) with every native target.
    public func fitRow(
      width: CGFloat, scale: CGFloat, typeSize: DynamicTypeSize,
      recording: [String], clock: String?, primary: String, details: [String],
      caption: String? = nil, maximumSize: CGFloat = 23, color: String? = nil,
      primaryIsDetail: Bool = false, maximumPrimarySize: CGFloat = 25, maximumDetailSize: CGFloat = 11
    ) -> MonitorPortraitPrimaryFit {
      fit(
        width: width, scale: scale, typeSize: typeSize, recording: recording,
        clock: clock, primary: primary, details: details, inline: true, caption: caption,
        maximumSize: maximumSize, color: color, primaryIsDetail: primaryIsDetail,
        maximumPrimarySize: maximumPrimarySize, maximumDetailSize: maximumDetailSize)
    }

    private func fit(
      width: CGFloat, scale: CGFloat, typeSize: DynamicTypeSize,
      recording: [String], clock: String?, primary: String, details: [String],
      inline: Bool, caption: String?, maximumSize: CGFloat, color: String?,
      primaryIsDetail: Bool, maximumPrimarySize: CGFloat = 25, maximumDetailSize: CGFloat = 11
    ) -> MonitorPortraitPrimaryFit {
      let key = Key(
        width: width, scale: max(1, scale), typeSize: typeSize,
        recording: recording, clock: clock.map(portraitClockShape), primary: primary,
        primaryIsDetail: primaryIsDetail, details: details, color: color, inline: inline,
        caption: caption,
        maximumSize: maximumSize.isFinite ? max(23, maximumSize) : 23,
        maximumPrimarySize: maximumPrimarySize.isFinite ? max(10, maximumPrimarySize) : 25,
        maximumDetailSize: maximumDetailSize.isFinite ? max(10, maximumDetailSize) : 11)
      if let cached, cached.key == key { return cached.fit }
      MonitorTheme.prepareResources()
      let trait = UITraitCollection(preferredContentSizeCategory: category(typeSize))
      let pixel = 1 / key.scale
      func measured(_ value: String, _ size: CGFloat, semibold: Bool = false, tracking: CGFloat = 0)
        -> CGFloat
      {
        guard let base = UIFont(name: semibold ? "Sora-SemiBold" : "Sora-Medium", size: size) else {
          return .infinity
        }
        let descriptor = base.fontDescriptor.addingAttributes([
          .featureSettings: [
            [
              UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
              UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]
          ]
        ])
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
          for: UIFont(descriptor: descriptor, size: size), compatibleWith: trait)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let text = NSAttributedString(string: value, attributes: attributes)
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * key.scale)
          / key.scale
      }
      let recordingTextWidth = recording.reduce(CGFloat(0)) {
        $0 + measured($1, 10, semibold: true)
      }
      let detailWidth =
        details.isEmpty
        ? 44
        : details.reduce(CGFloat(0)) { $0 + max(44, measured($1, 11)) } + CGFloat(
          max(0, details.count - 1)) * 24
      let count = (recording.isEmpty ? 0 : 1) + (clock == nil ? 0 : 1) + 1
      var selected =
        inline
        ? MonitorPortraitPrimaryFit(
          clockSize: 10, primarySize: 10, spacing: 0.5,
          completeSingleRow: false, detailSize: 10, recordingPadding: 0,
          recordingSpacing: 0)
        : MonitorPortraitPrimaryFit(
          clockSize: 13.5, primarySize: 14, spacing: 4, completeSingleRow: false)
      if width.isFinite && width > 0 {
        // Prefer regular legibility, then admit a compact text-only tier. Targets retain their floor.
        let tiers: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] =
          inline
          ? [
            (15, 16, 8, 8, 5), (15, 16, 4, 4, 3), (13.5, 14, 2, 2, 2),
            (11, 11, 0.5, 0, 0), (10, 10, 0.5, 0, 0),
          ]
          : [(15, 16, 8, 8, 5), (15, 16, 4, 8, 5), (13.5, 14, 4, 8, 5)]
        let options: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]
        if inline {
          options =
            (0...Int(ceil((key.maximumSize - 10) / 0.25))).flatMap { step in
              let size = key.maximumSize - CGFloat(step) * 0.25
              return tiers.compactMap {
                tier -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)? in
                let (clockFloor, primaryFloor, spacing, padding, recordingSpacing) =
                  tier
                let detailFloor: CGFloat = clockFloor == 10 ? 10 : 11
                guard size >= max(clockFloor, primaryFloor), size >= detailFloor else {
                  return nil
                }
                return (size, min(key.maximumPrimarySize, size), min(key.maximumDetailSize, size), spacing, padding, recordingSpacing, 0)
              }
            }
            + (1...7).map {
              step -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) in
              // Compact tracking follows the complete natural-width 10-point floor.
              (10, 10, 10, 0.5, 0, 0, -0.125 * CGFloat(step))
            }
        } else {
          options = tiers.flatMap {
            clockFloor, primaryFloor, spacing, padding, recordingSpacing in
            (0...38).map { step in
              let size = key.maximumSize - CGFloat(step) * 0.25
              return (
                max(clockFloor, size), max(primaryFloor, size), 11, spacing,
                padding, recordingSpacing, 0
              )
            }
          }
        }
        // Choose the largest complete text first, then the most comfortable spacing that fits.
        for (
          clockSize, primarySize, detailSize, spacing, recordingPadding, recordingSpacing, tracking
        ) in options {
          let separatorWidth: CGFloat =
            inline && recordingSpacing == 0
            ? recording.first.map {
              measured($0 + " ", 10, semibold: true, tracking: tracking)
                - measured($0, 10, semibold: true, tracking: tracking)
            } ?? 0 : 0
          let trackedRecordingWidth =
            tracking == 0
            ? recordingTextWidth
            : recording.reduce(CGFloat(0)) {
              $0 + measured($1, 10, semibold: true, tracking: tracking)
            }
          let recordingWidth =
            recording.isEmpty
            ? 0
            : trackedRecordingWidth + separatorWidth + 2 * recordingPadding
              + recordingSpacing
          let clockWidth =
            key.clock.map { measured($0, clockSize, tracking: tracking) + pixel } ?? 0
          let formatWidth: CGFloat
          if inline {
            // The format group stacks: the primary line above, codec, color and caption on
            // the detail line below, so the group is as wide as its wider line.
            let lowerItems = details + [color, caption].compactMap { $0 }
            let lowerWidth =
              lowerItems.reduce(CGFloat(0)) {
                $0 + max(44, measured($1, detailSize, tracking: tracking) + pixel)
              } + CGFloat(max(0, lowerItems.count - 1)) * spacing
            formatWidth = max(
              44,
              measured(primary, primaryIsDetail ? detailSize : primarySize, tracking: tracking)
                + pixel,
              lowerWidth)
          } else {
            formatWidth = max(44, detailWidth, measured(primary, primarySize) + pixel)
          }
          if recordingWidth + clockWidth + formatWidth + CGFloat(max(0, count - 1))
            * spacing <= width - 2 * pixel
          {
            selected = .init(
              clockSize: clockSize, primarySize: primarySize,
              spacing: spacing, completeSingleRow: true, detailSize: detailSize,
              recordingPadding: recordingPadding, recordingSpacing: recordingSpacing,
              tracking: tracking)
            break
          }
        }
      }
      cached = (key, selected)
      return selected
    }

    private func category(_ value: DynamicTypeSize) -> UIContentSizeCategory {
      switch value {
      case .xSmall: .extraSmall
      case .small: .small
      case .medium: .medium
      case .large: .large
      case .xLarge: .extraLarge
      case .xxLarge: .extraExtraLarge
      case .xxxLarge: .extraExtraExtraLarge
      case .accessibility1: .accessibilityMedium
      case .accessibility2: .accessibilityLarge
      case .accessibility3: .accessibilityExtraLarge
      case .accessibility4: .accessibilityExtraExtraLarge
      case .accessibility5: .accessibilityExtraExtraExtraLarge
      @unknown default: .large
      }
    }
  }

  /// One complete label in the stacked portrait format group. An impossible budget stays an explicit failed fit.
  public struct MonitorPortraitInlineReadoutText: View {
    @Environment(\.monitorPortraitPrimaryFit) private var fit
    private let value: String
    private let detail: Bool
    public init(_ value: String, detail: Bool = false) {
      self.value = value
      self.detail = detail
    }
    public var body: some View {
      Text(value).font(
        MonitorTheme.font(
          detail ? (fit?.detailSize ?? 11) : (fit?.primarySize ?? 23), weight: .medium)
      )
      .tracking(fit?.tracking ?? 0)
      .monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: true)
      .padding(.top, detail ? 0 : fit.map(MonitorPortraitCapAlignment.primaryInset) ?? 0)
      .accessibilityLabel(value)
    }
  }

  /// The status row aligns its items by their top edge. A primary drawn smaller than the clock
  /// (the fitter caps it) would then paint its capitals higher than the clock's digits, since a
  /// line's top sits above its cap height by an amount that grows with the size. The inset moves
  /// the primary's paint down by that difference, so the painted tops line up; the target keeps
  /// its frame top.
  enum MonitorPortraitCapAlignment {
    /// Space above the cap height in one point of Sora Medium, the face of the clock and primary.
    private static let unitTopToCap: CGFloat = {
      guard let font = UIFont(name: "Sora-Medium", size: 100) else { return 0 }
      return (font.ascender - font.capHeight) / 100
    }()

    static func primaryInset(_ fit: MonitorPortraitPrimaryFit) -> CGFloat {
      max(0, (fit.clockSize - fit.primarySize) * unitTopToCap)
    }
  }

  /// A failed row budget wraps complete format/codec text at the font floor; it never ellipsizes.
  public struct MonitorPortraitReadoutText: View {
    @Environment(\.monitorPortraitPrimaryFit) private var fit
    private let value: String
    private let detail: Bool
    public init(_ value: String, detail: Bool = false) {
      self.value = value
      self.detail = detail
    }
    public var body: some View {
      Text(value).font(MonitorTheme.font(detail ? 11 : (fit?.primarySize ?? 23), weight: .medium))
        .monospacedDigit().lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(value)
    }
  }
#endif
