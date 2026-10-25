#if os(iOS)
  import MonitorPresentation
  import SwiftUI

  /// Common status composition. Integrations fill only their format, color, mode and telemetry readouts.
  public struct MonitorStatusChrome<
    Storage: View, Format: View, ColorProfile: View, Mode: View, Link: View
  >: View {
    @Environment(\.monitorPortraitPrimaryFit) private var primaryFit
    private let layout: FieldMonitorLayout
    private let status: MonitorStatusPresentation
    private let showsTimecode: Bool
    private let showsRecording: Bool
    private let showsCompactTelemetry: Bool
    private let minimumOccupiedTop: Double
    private let clock: (() -> String?)?
    private let storage: () -> Storage
    private let format: () -> Format
    private let color: () -> ColorProfile
    private let mode: () -> Mode
    private let link: () -> Link

    public init(
      layout: FieldMonitorLayout, status: MonitorStatusPresentation,
      showsTimecode: Bool = true, showsRecording: Bool = true, showsCompactTelemetry: Bool = true,
      minimumOccupiedTop: Double = 0, clock: (() -> String?)? = nil,
      @ViewBuilder storage: @escaping () -> Storage,
      @ViewBuilder format: @escaping () -> Format,
      @ViewBuilder color: @escaping () -> ColorProfile,
      @ViewBuilder mode: @escaping () -> Mode,
      @ViewBuilder link: @escaping () -> Link
    ) {
      self.layout = layout
      self.status = status
      self.showsTimecode = showsTimecode
      self.showsRecording = showsRecording
      self.showsCompactTelemetry = showsCompactTelemetry
      self.minimumOccupiedTop = minimumOccupiedTop
      self.clock = clock
      self.storage = storage
      self.format = format
      self.color = color
      self.mode = mode
      self.link = link
    }

    public var body: some View {
      Group {
        if layout.portrait {
          MonitorPortraitStatusLayout(
            minimumHeight: layout.status.height, availableTop: layout.status.y,
            minimumOccupiedTop: minimumOccupiedTop, spacing: primaryFit?.spacing ?? 8,
            allowsFallbackRows: !(primaryFit?.completeSingleRow ?? false)
          ) {
            HStack(spacing: 0) { if showsRecording { MonitorRecordingReadout(status: status) } }
            HStack(spacing: 0) {
              if showsTimecode {
                MonitorStatusClockSlot(read: clock, fallback: status.timecode) { shown in
                  if let primaryFit, primaryFit.tracking < 0 {
                    MonitorPortraitTrackedClock(
                      shown, placeholder: status.timecodePlaceholder, fit: primaryFit)
                  } else {
                    MonitorClock(
                      shown, placeholder: status.timecodePlaceholder,
                      fontSize: primaryFit?.clockSize ?? (layout.tablet ? 25 : 23))
                  }
                }
              }
            }
            .fixedSize(horizontal: primaryFit != nil, vertical: false)
            HStack(alignment: .top, spacing: primaryFit?.spacing ?? 8) {
              format()
              color()
            }
          }
        } else {
          HStack(spacing: 24) {
            storage()
            format()
            color()
            mode()
            Spacer(minLength: 4)
            HStack(spacing: 10) {
              if showsRecording { MonitorRecordingReadout(status: status) }
              if showsTimecode {
                MonitorStatusClockSlot(read: clock, fallback: status.timecode) { shown in
                  MonitorClock(shown, placeholder: status.timecodePlaceholder, fontSize: layout.tablet ? 25 : 23)
                }
              }
            }
            .padding(.trailing, layout.recordingReadoutTrailingInset)
          }
        }
      }
      .frame(height: layout.portrait ? nil : layout.status.height)
      .monitorReadoutShadow()
      .overlay(alignment: .topLeading) {
        if layout.portrait, showsCompactTelemetry {
          if layout.tablet {
            HStack(spacing: 10) { storage().monitorReadoutShadow() }
              .offset(y: 52 - layout.status.y)
          } else {
            MonitorPortraitTelemetryLayout {
              storage().monitorReadoutShadow()
              link().fixedSize(horizontal: true, vertical: false)
            }
            .frame(
              width: max(0, layout.telemetry.x - layout.status.x - 8), height: 48,
              alignment: .leading
            )
            .offset(y: layout.telemetry.y - 13 - layout.status.y)
          }
        }
      }
    }
  }

  /// Reads a source's live clock in its own body. A timecode that advances every live view frame
  /// then re-renders this readout only, not the status composition and the surface that hold it
  /// (lane media-perf 2026-10-25: Z's per-frame timecode re-evaluated the whole live surface).
  /// Without a reader the status value shows, as before.
  private struct MonitorStatusClockSlot<Clock: View>: View {
    let read: (() -> String?)?
    let fallback: String?
    @ViewBuilder let render: (String?) -> Clock
    var body: some View { render(read.map { $0() } ?? fallback) }
  }

  /// Reserve performance first; storage scales inside its remaining slot.
  private struct MonitorPortraitTelemetryLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let measured = frames(proposal: proposal, subviews: subviews)
      return CGSize(
        width: measured.0.width + 8 + measured.1.width,
        height: max(measured.0.height, measured.1.height))
    }
    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      guard subviews.count == 2 else { return }
      let measured = frames(
        proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
        subviews: subviews)
      subviews[0].place(
        at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: measured.0.width, height: measured.0.height))
      subviews[1].place(
        at: CGPoint(x: bounds.minX + measured.0.width + 8, y: bounds.midY),
        anchor: .leading,
        proposal: ProposedViewSize(width: measured.1.width, height: measured.1.height))
    }
    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> (CGSize, CGSize) {
      guard subviews.count == 2 else { return (.zero, .zero) }
      let link = subviews[1].sizeThatFits(.unspecified)
      let width = max(0, (proposal.width ?? .infinity) - link.width - 8)
      let storage = subviews[0].sizeThatFits(
        ProposedViewSize(width: width, height: proposal.height))
      return (CGSize(width: min(width, storage.width), height: storage.height), link)
    }
  }

  /// Preserve complete intrinsic values on one row while a complete typed fit owns it.
  /// Without such a fit context the original fallback applies: an impossible single row
  /// wraps complete groups to intrinsic rows below instead of placing them beyond the
  /// width, so nothing is clipped and no glyph is dropped or ellipsized.
  private struct MonitorPortraitStatusLayout: Layout {
    let minimumHeight: CGFloat
    let availableTop: CGFloat
    let minimumOccupiedTop: CGFloat
    let spacing: CGFloat
    let allowsFallbackRows: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      frames(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      let measured = frames(width: bounds.width, subviews: subviews)
      for (view, frame) in zip(subviews, measured.slots) {
        let x = bounds.minX + frame.minX
        view.place(
          at: CGPoint(x: x, y: bounds.minY + frame.minY), anchor: .topLeading,
          proposal: ProposedViewSize(width: frame.width, height: frame.height))
      }
    }

    private func frames(width proposal: CGFloat?, subviews: Subviews) -> (
      size: CGSize, slots: [CGRect]
    ) {
      let intrinsic = subviews.map { $0.sizeThatFits(.unspecified) }
      let count = intrinsic.filter { $0.width > 0 }.count
      let needed = intrinsic.reduce(0) { $0 + $1.width } + CGFloat(max(0, count - 1)) * spacing
      let width = proposal.map { $0.isFinite ? max(1, $0) : max(1, needed) } ?? max(1, needed)
      let measured = intrinsic
      guard measured.count == 3 else { return (CGSize(width: width, height: minimumHeight), []) }
      let recording = measured[0]
      let clock = measured[1]
      let format = measured[2]
      let hasRecording = recording.width > 0
      let hasClock = clock.width > 0
      let hasFormat = format.width > 0
      let wraps = allowsFallbackRows && needed > width
      let secondRow = wraps && hasFormat && (hasRecording || hasClock)
      let separatesClock = wraps && hasRecording && hasClock
        && recording.width + spacing + clock.width > width
      let lower = hasRecording && !separatesClock ? recording.width + spacing : 0
      let upper = width - clock.width - (hasFormat && !secondRow ? format.width + spacing : 0)
      let clockX = hasClock ? max(lower, min((width - clock.width) / 2, upper)) : 0
      let firstHeight = max(
        minimumHeight, recording.height,
        separatesClock ? 0 : clock.height, secondRow ? 0 : format.height)
      let clockY: CGFloat = separatesClock ? firstHeight + spacing : 0
      let clockFloor = separatesClock ? clockY + clock.height : firstHeight
      let formatRowHeight = secondRow ? max(minimumHeight, format.height) : format.height
      let formatY: CGFloat = secondRow ? clockFloor + spacing : 0
      let afterClock = hasClock ? clockX + clock.width + spacing : lower
      let formatX = secondRow
        ? max(0, width - format.width)
        : max(afterClock, width - format.width)
      let height = max(
        minimumHeight, firstHeight, format.height,
        separatesClock ? clockFloor : 0,
        secondRow ? formatY + formatRowHeight : 0)
      let formatDimensions = subviews[2].dimensions(
        in: ProposedViewSize(width: format.width, height: format.height))
      let targetTop = formatDimensions[explicit: .monitorPortraitCaptureTargetTop] ?? 0
      // Read the unshifted target edge, including fallback-row placement. Only an actual
      // viewport obstruction moves the complete status row; independent telemetry stays fixed.
      let occupiedTop = min(0, formatY + targetTop)
      let clearance = max(0, minimumOccupiedTop - (availableTop + occupiedTop))
      return (
        CGSize(width: width, height: height + clearance),
        [
          CGRect(x: 0, y: clearance, width: recording.width, height: recording.height),
          CGRect(x: clockX, y: clockY + clearance, width: clock.width, height: clock.height),
          CGRect(x: formatX, y: formatY + clearance, width: format.width, height: format.height),
        ]
      )
    }
  }

  /// Camera telemetry supplies elapsed time. Unknown recording never displays Standby.
  public struct MonitorRecordingReadout: View {
    @Environment(\.monitorPortraitPrimaryFit) private var primaryFit
    private let status: MonitorStatusPresentation
    public init(status: MonitorStatusPresentation) { self.status = status }
    public var body: some View {
      HStack(spacing: primaryFit?.recordingSpacing ?? 5) {
        Text(status.recordingLabel + (primaryFit?.recordingSpacing == 0 ? " " : ""))
          .tracking(primaryFit?.tracking ?? 0)
          .foregroundStyle(status.recording == true ? MonitorTheme.recording : .white)
        Text(status.elapsedLabel).tracking(primaryFit?.tracking ?? 0).foregroundStyle(
          MonitorTheme.secondary)
      }
      .font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
      .padding(.horizontal, primaryFit?.recordingPadding ?? 8).padding(.vertical, 4)
      .background(.black.opacity(0.65), in: Capsule()).fixedSize()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(status.recordingAccessibilityLabel)
      .accessibilityValue(
        status.elapsedSeconds == nil ? "Elapsed time unknown" : status.elapsedLabel
      )
      .accessibilityIdentifier("monitor.recording.readout")
    }
  }

  private struct MonitorPortraitTrackedClock: View {
    let clock: String?
    let placeholder: String
    let fit: MonitorPortraitPrimaryFit
    init(_ clock: String?, placeholder: String, fit: MonitorPortraitPrimaryFit) {
      self.clock = clock
      self.placeholder = placeholder
      self.fit = fit
    }
    var body: some View {
      let displayed = clock ?? placeholder
      let components = MonitorTimecodeFormat.accentComponents(in: displayed)
      (Text(components.base).foregroundColor(.white)
        + Text(components.accent).foregroundColor(MonitorTheme.accent))
        .font(MonitorTheme.font(fit.clockSize, weight: .medium)).monospacedDigit()
        .tracking(fit.tracking).lineLimit(1).fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(clock.map { "Timecode \($0)" } ?? "Timecode not available")
    }
  }
#endif
