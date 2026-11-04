import MonitorPresentation
import Testing

/// The landscape feed frame: a picture taller than 16:9 (a 3:2 or 4:3 still) is scaled down to
/// fit inside the 16:9 region a video picture fills, keeping the video's black bars top and
/// bottom and every control where video has it. Same table as Kotlin `LandscapeFeedFrameTest`.
struct LandscapeFeedFrameTests {
    /// A landscape screen: its size in points and the cutout inset on one long edge.
    struct Screen: CustomStringConvertible, Sendable {
        let name: String
        let width: Double
        let height: Double
        let leading: Double
        let bottom: Double
        var description: String { name }

        func layout(_ aspect: Double) -> FieldMonitorLayout {
            FieldMonitorLayout(
                width: width, height: height,
                safeArea: .init(top: 0, leading: leading, bottom: bottom),
                sourceAspect: aspect, valueCount: 9)
        }
    }

    static let iPad11 = Screen(name: "iPad 11-inch", width: 1210, height: 834, leading: 0, bottom: 20)
    static let iPadClassic = Screen(name: "iPad 4:3", width: 1024, height: 768, leading: 0, bottom: 20)
    static let androidTablet = Screen(name: "Android tablet", width: 1280, height: 800, leading: 0, bottom: 0)
    static let iPhone = Screen(name: "iPhone 16 Pro", width: 874, height: 402, leading: 62, bottom: 21)
    static let androidPhone = Screen(name: "Android phone", width: 915, height: 412, leading: 30, bottom: 0)

    /// Expected picture rect (x, y, width, height) for each screen and source aspect.
    static let table: [(Screen, Double, (Double, Double, Double, Double))] = [
        // Tablets: one 16:9 frame; a taller picture fits inside it, pillarboxed.
        (iPad11, 16.0 / 9, (0, 76.6875, 1210, 680.625)),
        (iPad11, 3.0 / 2, (94.53125, 76.6875, 1020.9375, 680.625)),
        (iPad11, 4.0 / 3, (151.25, 76.6875, 907.5, 680.625)),
        (iPadClassic, 16.0 / 9, (0, 96, 1024, 576)),
        (iPadClassic, 3.0 / 2, (80, 96, 864, 576)),
        (iPadClassic, 4.0 / 3, (128, 96, 768, 576)),
        (androidTablet, 16.0 / 9, (0, 40, 1280, 720)),
        (androidTablet, 3.0 / 2, (100, 40, 1080, 720)),
        (androidTablet, 4.0 / 3, (160, 40, 960, 720)),
        // Phones are wider than 16:9: the frame is already full height, so the rule leaves
        // every picture where it was.
        (iPhone, 16.0 / 9, (79.666_667, 0, 714.666_667, 402)),
        (iPhone, 3.0 / 2, (135.5, 0, 603, 402)),
        (iPhone, 4.0 / 3, (169, 0, 536, 402)),
        (androidPhone, 16.0 / 9, (91.277_778, 0, 732.444_444, 412)),
        (androidPhone, 3.0 / 2, (148.5, 0, 618, 412)),
        (androidPhone, 4.0 / 3, (182.833_333, 0, 549.333_333, 412)),
    ]

    @Test(arguments: table.indices)
    func pictureFitsInsideTheVideoFrame(index: Int) {
        let (screen, aspect, expected) = Self.table[index]
        let picture = screen.layout(aspect).picture
        let label = "\(screen) aspect \(aspect)"
        #expect(abs(picture.x - expected.0) < 0.001, "\(label) x \(picture.x)")
        #expect(abs(picture.y - expected.1) < 0.001, "\(label) y \(picture.y)")
        #expect(abs(picture.width - expected.2) < 0.001, "\(label) width \(picture.width)")
        #expect(abs(picture.height - expected.3) < 0.001, "\(label) height \(picture.height)")
        #expect(abs(picture.width / picture.height - aspect) < 0.0001, "\(label) keeps its shape")
    }

    /// A still keeps the video's bars and controls: only the picture inside the frame changes.
    /// On a tablet the status row stays where video has it, over the top bar.
    @Test(arguments: [iPad11, iPadClassic, androidTablet, iPhone, androidPhone])
    func tallerPictureKeepsEveryControlWhereVideoHasIt(screen: Screen) {
        let video = screen.layout(16.0 / 9)
        for aspect in [3.0 / 2, 4.0 / 3] {
            let still = screen.layout(aspect)
            #expect(abs(still.picture.y - video.picture.y) < 0.001, "\(screen) \(aspect) top bar")
            #expect(abs(still.picture.maxY - video.picture.maxY) < 0.001, "\(screen) \(aspect) bottom bar")
            #expect(abs(still.picture.midX - video.picture.midX) < 0.001, "\(screen) \(aspect) centred")
            if still.tablet {
                #expect(still.status == video.status, "\(screen) \(aspect) status row")
            } else {
                // A phone's picture runs the full height: the status row stays on the picture.
                #expect(
                    abs(still.status.x - (still.picture.x + 12)) < 0.001,
                    "\(screen) \(aspect) status row")
            }
            #expect(still.values == video.values, "\(screen) \(aspect) camera values")
            #expect(still.record == video.record, "\(screen) \(aspect) record")
            #expect(still.settings == video.settings, "\(screen) \(aspect) settings")
            #expect(still.media == video.media, "\(screen) \(aspect) media")
            #expect(still.lock == video.lock, "\(screen) \(aspect) lock")
            #expect(still.assists == video.assists, "\(screen) \(aspect) assists")
            #expect(still.stick == video.stick, "\(screen) \(aspect) joystick")
        }
    }

    /// The recenter key (and AE unlock beside it) without a motion cluster sits on the scaled
    /// picture, inside its trailing bottom corner, so it never floats in the black pillarbox.
    @Test(arguments: [iPad11, androidTablet])
    func recenterSitsOnTheScaledPicture(screen: Screen) {
        let layout = screen.layout(3.0 / 2)
        let reset = layout.focusReset(motionCluster: false)
        #expect(reset.x >= layout.picture.x && reset.maxX <= layout.picture.maxX, "\(screen)")
        #expect(reset.y >= layout.picture.y && reset.maxY <= layout.picture.maxY, "\(screen)")
        let unlock = layout.aeUnlock(motionCluster: false)
        #expect(unlock.x >= layout.picture.x && unlock.maxX <= layout.picture.maxX, "\(screen)")
    }

    /// A picture wider than 16:9 is not shrunk into the frame: it still spans the usable width.
    @Test func widerPictureKeepsTheFullWidth() {
        let iPad = Self.iPad11.layout(2.39)
        #expect(iPad.picture.width == 1210)
        let phone = Self.iPhone.layout(2.39)
        #expect(phone.picture.x == 48)
        #expect(phone.picture.width == 778)
    }

    /// Portrait has room above and below the picture, so a still keeps the full width there
    /// (taller than a video picture, centred between the status row and the camera values).
    @Test func portraitStillKeepsTheFullWidth() {
        for (width, height) in [(834.0, 1210.0), (402, 874)] {
            let layout = FieldMonitorLayout(
                width: width, height: height, safeArea: .init(top: 24, bottom: 20),
                sourceAspect: 3.0 / 2)
            #expect(layout.picture.width == width, "\(width)")
            #expect(abs(layout.picture.height - width / 1.5) < 0.001, "\(width)")
        }
    }
}
