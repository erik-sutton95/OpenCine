#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Actual catalog Grid/List composition. The sole content slot supplies source artwork.
    public struct MonitorMediaCell<Thumbnail: View>: View {
        private let clip: MonitorClipValue
        private let layout: MonitorMediaLayout
        private let tablet: Bool
        private let selecting: Bool
        private let selected: Bool
        private let favoriteEnabled: Bool
        private let favoriteBesideTitle: Bool
        private let sourceTint: Color
        private let onOpen: () -> Void
        private let onSelect: () -> Void
        private let onFavorite: (() -> Void)?
        private let onBeginSelection: (() -> Void)?
        private let entryHoldDuration: Double
        private let thumbnail: Thumbnail

        public init(
            clip: MonitorClipValue, layout: MonitorMediaLayout, tablet: Bool = false,
            selecting: Bool, selected: Bool, favoriteEnabled: Bool = true,
            favoriteBesideTitle: Bool = false, sourceTint: Color = MonitorTheme.muted,
            onOpen: @escaping () -> Void, onSelect: @escaping () -> Void,
            onFavorite: (() -> Void)? = nil, onBeginSelection: (() -> Void)? = nil,
            entryHoldDuration: Double = 0.4,
            @ViewBuilder thumbnail: () -> Thumbnail
        ) {
            self.clip = clip
            self.layout = layout
            self.tablet = tablet
            self.selecting = selecting
            self.selected = selected
            self.favoriteEnabled = favoriteEnabled
            self.favoriteBesideTitle = favoriteBesideTitle
            self.sourceTint = sourceTint
            self.onOpen = onOpen
            self.onSelect = onSelect
            self.onFavorite = onFavorite
            self.onBeginSelection = onBeginSelection
            self.entryHoldDuration = entryHoldDuration
            self.thumbnail = thumbnail()
        }

        public var body: some View {
            // Named like the Compose cell: the app's description, else the clip's title.
            cell.accessibilityLabel(clip.accessibilityDescription ?? clip.title)
        }

        private var cell: some View {
            Group {
                if layout == .grid { gridCard } else { listRow }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(.default) {
                selecting ? onSelect() : onOpen()
            }
            .accessibilityAction(
                named: selecting ? "Toggle selection" : (clip.selectionEntryLabel ?? "Select clip")
            ) {
                onSelect()
            }
        }

        private var gridCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                browsingEntry(
                    artwork
                        .aspectRatio(16.0 / 9.0, contentMode: .fit).clipped()
                        .overlay(alignment: .topLeading) {
                            if selecting {
                                selectButton.padding(2)
                            } else if let count = clip.burstCount {
                                badge("\(count) frames").padding(6)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if !favoriteBesideTitle { favoriteButton.padding(2) }
                        }
                        .overlay(alignment: .bottomLeading) { stateTag.padding(6) }
                        .overlay(alignment: .bottomTrailing) {
                            VStack(alignment: .trailing, spacing: 3) {
                                if let badge = clip.mediaBadge { self.badge(badge) }
                                durationTag
                                if let badge = clip.completionBadge { self.badge(badge) }
                            }.padding(6)
                        }
                        .overlay(alignment: .bottom) { progressBar }
                        .contentShape(Rectangle())
                        .onTapGesture { selecting ? onSelect() : onOpen() }
                )
                HStack(spacing: 4) {
                    captions(titleSize: 10.5, detailSize: 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if favoriteBesideTitle { favoriteButton }
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
            }
            .background(MonitorTheme.surface).clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay { selectedOverlay(radius: 11) }
        }

        private var listRow: some View {
            browsingEntry(
                HStack(spacing: 10) {
                    if selecting { selectButton }
                    artwork.frame(width: tablet ? 96 : 76, height: tablet ? 54 : 43)
                        .clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomTrailing) { durationTag }
                    captions(titleSize: 11.5, detailSize: 9.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tablet {
                        Text(clip.format ?? "").font(MonitorTheme.font(10.5))
                            .frame(width: 100, alignment: .leading)
                        Text(clip.color ?? "").font(MonitorTheme.font(9, weight: .bold)).frame(
                            width: 70)
                        stateTag
                    }
                    favoriteButton
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .foregroundStyle(MonitorTheme.secondary)
                .contentShape(Rectangle())
                .onTapGesture { selecting ? onSelect() : onOpen() }
                .overlay { selectedOverlay(radius: 0) }
            )
        }

        private var artwork: some View {
            thumbnail.overlay {
                if let caption = clip.transferCaption {
                    ZStack {
                        Color.black.opacity(0.45)
                        Text(caption).font(MonitorTheme.font(10, weight: .bold))
                            .monospacedDigit().foregroundStyle(MonitorTheme.text)
                    }
                }
            }
        }

        private func captions(titleSize: CGFloat, detailSize: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title).font(MonitorTheme.font(titleSize, weight: .semibold))
                    .foregroundStyle(MonitorTheme.text)
                Text(clip.detail).font(MonitorTheme.font(detailSize)).foregroundStyle(
                    MonitorTheme.faint)
            }.lineLimit(1)
        }

        /// Browsing entry remains separate from the armed native selection host.
        @ViewBuilder private func browsingEntry<Content: View>(_ content: Content) -> some View {
            if let onBeginSelection {
                content.onLongPressGesture(minimumDuration: entryHoldDuration) {
                    if !selecting { onBeginSelection() }
                }
            } else {
                content
            }
        }

        private var selectButton: some View {
            Button(action: onSelect) {
                (selected ? MonitorIcon.circleCheck : .circle)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(selected ? MonitorTheme.accent : .white.opacity(0.7))
                    .background(.black.opacity(0.4), in: Circle()).frame(width: 44, height: 44)
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel(selected ? "Deselect \(clip.title)" : "Select \(clip.title)")
        }

        @ViewBuilder private var favoriteButton: some View {
            if let onFavorite {
                Button(action: onFavorite) {
                    MonitorIcon.star.view(filled: clip.favorite).frame(width: 13, height: 13)
                        .foregroundStyle(
                            clip.favorite ? MonitorTheme.color(0xE9C35A) : .white.opacity(0.7)
                        )
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(MonitorButtonStyle()).disabled(!favoriteEnabled)
                .accessibilityLabel(
                    clip.favoriteLabel ?? (clip.favorite ? "Remove favorite" : "Add favorite"))
            }
        }

        @ViewBuilder private var stateTag: some View {
            if let source = clip.source {
                Text(source).font(MonitorTheme.font(8, weight: .bold)).tracking(0.4)
                    .foregroundStyle(clip.progress != nil ? MonitorTheme.accent : sourceTint)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 4))
            }
        }

        private var durationTag: some View {
            Text(clip.duration ?? "").font(MonitorTheme.font(9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 3)
                .background(
                    clip.duration == nil || clip.duration == "" ? .clear : .black.opacity(0.66),
                    in: RoundedRectangle(cornerRadius: 4))
        }

        private func badge(_ text: String) -> some View {
            Text(text).font(MonitorTheme.font(8, weight: .bold)).foregroundStyle(MonitorTheme.text)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 4))
        }

        @ViewBuilder private var progressBar: some View {
            if let progress = clip.progress {
                GeometryReader { proxy in
                    Rectangle().fill(MonitorTheme.accent)
                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                }.frame(height: 3).background(.black.opacity(0.5))
            }
        }

        @ViewBuilder private func selectedOverlay(radius: CGFloat) -> some View {
            if selected {
                RoundedRectangle(cornerRadius: radius).fill(MonitorTheme.accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(MonitorTheme.accent, lineWidth: 2)
                    ).allowsHitTesting(false)
            }
        }
    }
#endif
