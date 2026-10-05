import Testing

@testable import MonitorPresentation

@Suite struct MonitorLayoutPolicyTests {
    // 44pt side insets are corner padding, not a cutout; 59pt is a hardware cutout.
    static let cornerPadding = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 44)
    static let leadingCutout = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    static let trailingCutout = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59)

    /// Device orientation wins; `nil` orientation exercises the safe-area-only resolver.
    @Test(arguments: [
        (
            MonitorDeviceOrientation?.some(.landscapeLeft), cornerPadding,
            MonitorHorizontalLayoutDirection.standard
        ),
        (.landscapeRight, cornerPadding, .mirrored),
        (.unknown, trailingCutout, .mirrored),
        (.unknown, leadingCutout, .standard),
        (.portrait, trailingCutout, .standard),
        (.portraitUpsideDown, trailingCutout, .standard),
        (.landscapeLeft, trailingCutout, .standard),
        (nil, leadingCutout, .standard),
        (nil, trailingCutout, .mirrored),
        (nil, cornerPadding, .standard),
    ])
    func horizontalLayoutDirection(
        orientation: MonitorDeviceOrientation?,
        safeArea: MonitorEdgeInsets,
        expected: MonitorHorizontalLayoutDirection
    ) {
        let resolved =
            orientation.map {
                MonitorHorizontalLayoutDirection.resolve(deviceOrientation: $0, safeArea: safeArea)
            } ?? MonitorHorizontalLayoutDirection.resolve(for: safeArea)
        #expect(resolved == expected)
    }

    @Test func chromeInsetsUseMinimumMarginsWhenSafeAreaIsEmpty() {
        let insets = MonitorEdgeInsets.chrome(for: .zero)

        #expect(insets.top == 14)
        #expect(insets.leading == 16)
        #expect(insets.bottom == 12)
        #expect(insets.trailing == 18)
    }

    @Test func chromeInsetsAddSafeAreaOnlyToInteractiveChrome() {
        let safeArea = MonitorEdgeInsets(top: 24, leading: 59, bottom: 21, trailing: 44)
        let insets = MonitorEdgeInsets.chrome(for: safeArea)

        #expect(insets.top == 32)
        #expect(insets.leading == 71)
        #expect(insets.bottom == 29)
        #expect(insets.trailing == 56)
    }

    @Test func startupSideCutoutAvoidanceReservesOnlyTheNotchedSideLane() {
        let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
        let avoidance = StartupSideCutoutAvoidance.resolve(for: safeArea)

        #expect(avoidance.leading == 59)
        #expect(avoidance.trailing == 0)
        #expect(avoidance.hasSideCutout)
    }

    @Test func startupSideCutoutAvoidanceIgnoresOrdinaryCornerPadding() {
        let safeArea = MonitorEdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24)
        let avoidance = StartupSideCutoutAvoidance.resolve(for: safeArea)

        #expect(avoidance.leading == 0)
        #expect(avoidance.trailing == 0)
        #expect(!avoidance.hasSideCutout)
    }
}
