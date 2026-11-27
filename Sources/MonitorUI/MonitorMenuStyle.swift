import SwiftUI

extension View {
    /// Keeps a menu's own label. Optimized for Mac, Mac Catalyst draws a SwiftUI `Menu` as a
    /// pop-up button that drops an icon-only label, which left an empty box in its place.
    public func monitorMenuStyle() -> some View {
        #if targetEnvironment(macCatalyst)
            self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #else
            self
        #endif
    }
}
