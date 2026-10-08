#if os(iOS)
import SwiftUI

/// A settled scrub selects once; native decoding is never triggered by intermediate highlights.
private struct FilmstripItem<Value, ID: Hashable>: Identifiable {
    let value: Value
    let id: ID
}
public struct MonitorPhotoFilmstrip<Item, ID: Hashable, Thumbnail: View>: View {
    private let items: [Item]
    private let selected: ID
    private let keyOf: (Item) -> ID
    private let enabled: Bool
    private let label: (Item) -> String
    private let select: (ID) -> Void
    private let thumbnail: (Item) -> Thumbnail
    @State private var centered: ID?
    @State private var commit: Task<Void, Never>?
    public init(items: [Item], selected: ID, keyOf: @escaping (Item) -> ID, enabled: Bool = true,
        label: @escaping (Item) -> String, select: @escaping (ID) -> Void,
        @ViewBuilder thumbnail: @escaping (Item) -> Thumbnail) {
        self.items = items; self.selected = selected; self.enabled = enabled
        self.keyOf = keyOf; self.label = label; self.select = select; self.thumbnail = thumbnail
    }
    public var body: some View {
        GeometryReader { proxy in
            let sideInset = max(0, proxy.size.width / 2 - 23)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(items.map { FilmstripItem(value: $0, id: keyOf($0)) }) { item in
                        let highlighted = item.id == (centered ?? selected)
                        thumbnail(item.value).frame(width: highlighted ? 46 : 30, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(highlighted ? MonitorTheme.accent : .clear, lineWidth: 1.5))
                            .animation(.easeOut(duration: 0.15), value: highlighted)
                            .onTapGesture { if enabled { commit?.cancel(); select(item.id) } }
                            .accessibilityElement(children: .ignore).accessibilityLabel(label(item.value))
                            .accessibilityAddTraits(.isButton).accessibilityAction { if enabled { select(item.id) } }
                            .id(item.id)
                    }
                }.scrollTargetLayout()
            }.scrollPosition(id: $centered, anchor: .center).scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, sideInset, for: .scrollContent)
        }.frame(height: 56).padding(.vertical, 4)
            .onAppear { centered = selected }
            .onDisappear { commit?.cancel(); commit = nil }
            .onChange(of: enabled) { _, value in if !value { commit?.cancel(); commit = nil } }
            .onChange(of: centered) { _, value in
                commit?.cancel()
                guard enabled, let value, value != selected else { return }
                commit = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                    guard !Task.isCancelled else { return }
                    select(value)
                }
            }
            .onChange(of: selected) { _, value in
                guard centered != value else { return }
                withAnimation(.easeOut(duration: 0.2)) { centered = value }
            }
    }
}
#endif
