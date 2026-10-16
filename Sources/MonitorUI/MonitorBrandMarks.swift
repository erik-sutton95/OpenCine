#if os(iOS)
    import SwiftUI
    import UIKit

    /// A camera app's launch identity: its name, the monogram drawn when the AppLogo raster is
    /// missing, the mark's accent and the backdrop's corner glow. Values only.
    public struct MonitorBrandIdentity {
        public var name: String
        public var monogram: String
        /// Read when a mark draws, so a brand accent installed at launch shows.
        public var accent: () -> Color
        public var glow: Color

        public init(name: String, monogram: String, accent: @escaping () -> Color, glow: Color) {
            self.name = name
            self.monogram = monogram
            self.accent = accent
            self.glow = glow
        }
    }

    /// The camera apps' brand palette around the launch marks: the brand accent on black.
    private enum MonitorBrandMarkColors {
        static let surface = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
        static let ink = Color.white
        static let muted = Color(red: 160 / 255, green: 165 / 255, blue: 165 / 255)
    }

    /// App mark from the AppLogo raster; falls back to a drawn monogram.
    public struct MonitorBrandMark: View {
        private let brand: MonitorBrandIdentity
        private let size: CGFloat

        public init(_ brand: MonitorBrandIdentity, size: CGFloat = 72) {
            self.brand = brand
            self.size = size
        }

        public var body: some View {
            let cornerRadius = size * 0.22
            let accent = brand.accent()
            Group {
                if let logo = UIImage(named: "AppLogo") ?? UIImage(named: "AppLogo.png") {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(MonitorBrandMarkColors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(accent.opacity(0.55), lineWidth: max(1, size * 0.018))
                        )
                        .overlay {
                            Text(brand.monogram)
                                .font(MonitorTheme.font(size * 0.34, weight: .heavy))
                                .kerning(size * 0.02)
                                .foregroundStyle(accent)
                        }
                        .frame(width: size, height: size)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
            .accessibilityLabel(brand.name)
        }
    }

    /// The app's name as the launch splash sets it, with an optional subtitle.
    public struct MonitorBrandWordmark: View {
        private let brand: MonitorBrandIdentity
        private let fontSize: CGFloat
        private let subtitle: String?

        public init(_ brand: MonitorBrandIdentity, fontSize: CGFloat = 34, subtitle: String? = nil) {
            self.brand = brand
            self.fontSize = fontSize
            self.subtitle = subtitle
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: fontSize * 0.18) {
                Text(brand.name)
                    .font(MonitorTheme.font(fontSize, weight: .bold))
                    .foregroundStyle(MonitorBrandMarkColors.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(MonitorTheme.font(fontSize * 0.38, weight: .medium))
                        .foregroundStyle(MonitorBrandMarkColors.muted)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The launch backdrop: near-black diagonal with the brand's glow from the top leading corner.
    public struct MonitorBrandBackdrop: View {
        private let glow: Color

        public init(_ brand: MonitorBrandIdentity) {
            glow = brand.glow
        }

        public var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255),
                        Color(red: 14 / 255, green: 14 / 255, blue: 14 / 255),
                        Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [glow.opacity(0.28), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )
            }
            .ignoresSafeArea()
        }
    }

    /// The camera apps' launch splash: the shared launch geometry over this brand's marks.
    public struct MonitorBrandLaunchSplash: View {
        private let brand: MonitorBrandIdentity
        private let compact: Bool

        public init(_ brand: MonitorBrandIdentity, compact: Bool = false) {
            self.brand = brand
            self.compact = compact
        }

        public var body: some View {
            MonitorLaunchSplashContent(
                compact: compact,
                backdrop: { MonitorBrandBackdrop(brand) },
                mark: { MonitorBrandMark(brand, size: $0) },
                wordmark: { MonitorBrandWordmark(brand, fontSize: $0) })
        }
    }
#endif
