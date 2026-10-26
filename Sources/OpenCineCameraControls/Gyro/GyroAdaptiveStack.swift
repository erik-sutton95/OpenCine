#if os(iOS)
    import SwiftUI

    /// The gyro screens' one layout rule, drawn from the approved mockups. Portrait (narrower than
    /// tall): the header text on top, the visual filling the middle, the footer (button or hint)
    /// at the bottom, so the visual sits above the button. Landscape: the visual on the left half,
    /// header and footer stacked on the right half. Android's `GyroAdaptiveStack` follows the
    /// same rule.
    public struct GyroAdaptiveStack<Visual: View, Header: View, Footer: View>: View {
        private let visual: Visual
        private let header: Header
        private let footer: Footer

        public init(
            @ViewBuilder visual: () -> Visual, @ViewBuilder header: () -> Header,
            @ViewBuilder footer: () -> Footer
        ) {
            self.visual = visual()
            self.header = header()
            self.footer = footer()
        }

        public var body: some View {
            GeometryReader { proxy in
                let portrait = proxy.size.width < proxy.size.height
                Group {
                    if portrait {
                    VStack(spacing: 16) {
                        header.frame(maxWidth: .infinity)
                        visual.frame(maxWidth: .infinity, maxHeight: .infinity)
                        footer.frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    HStack(spacing: 24) {
                        visual.frame(width: max(0, proxy.size.width * 0.48 - 12))
                            .frame(maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            footer
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.trailing, 24)
                    }
                    .padding(.vertical, 16)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .environment(\.gyroIsLandscape, !portrait)
            }
        }
    }
#endif
