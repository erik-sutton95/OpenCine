#if os(iOS)
    import SwiftUI

    /// The gyro screens' one layout rule: portrait (narrower than tall) stacks the visual above
    /// the text and buttons; landscape puts the visual on the left half and the content on the
    /// right half. Android's `GyroAdaptiveStack` follows the same rule.
    public struct GyroAdaptiveStack<Visual: View, Content: View>: View {
        private let visual: Visual
        private let content: Content

        public init(@ViewBuilder visual: () -> Visual, @ViewBuilder content: () -> Content) {
            self.visual = visual()
            self.content = content()
        }

        public var body: some View {
            GeometryReader { proxy in
                if proxy.size.width < proxy.size.height {
                    VStack(spacing: 24) {
                        visual.frame(maxWidth: .infinity, maxHeight: .infinity)
                        content.frame(maxWidth: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    HStack(spacing: 24) {
                        visual.frame(width: proxy.size.width / 2 - 12).frame(maxHeight: .infinity)
                        content.frame(width: proxy.size.width / 2 - 12).frame(maxHeight: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }
#endif
