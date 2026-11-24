import Testing

@testable import OpenCineDesktopKit

/// A saved window frame must open on a display that is still attached.
@Suite struct WindowFrameTests {
    let screen = WindowFrame(x: 0, y: 0, width: 1920, height: 1080)

    @Test func frameOnScreenIsKept() {
        let frame = WindowFrame(x: 100, y: 100, width: 1280, height: 800)
        #expect(frame.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800) == frame)
    }

    @Test func frameOffEveryScreenFallsBackToCentredDefault() {
        let gone = WindowFrame(x: 3000, y: 0, width: 1280, height: 800)
        #expect(
            gone.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800)
                == WindowFrame(x: 320, y: 140, width: 1280, height: 800))
    }

    @Test func barelyVisibleFrameFallsBack() {
        let edge = WindowFrame(x: 1880, y: 0, width: 1280, height: 800)  // 40 pt visible
        #expect(edge.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800).x == 320)
    }

    @Test func frameOnASecondScreenIsKept() {
        let second = WindowFrame(x: 1920, y: 0, width: 2560, height: 1440)
        let frame = WindowFrame(x: 2000, y: 100, width: 1280, height: 800)
        #expect(frame.fitted(onto: [screen, second], defaultWidth: 1280, defaultHeight: 800) == frame)
    }

    @Test func defaultIsClippedToASmallScreen() {
        let small = WindowFrame(x: 0, y: 0, width: 1024, height: 700)
        let gone = WindowFrame(x: 5000, y: 0, width: 1280, height: 800)
        #expect(
            gone.fitted(onto: [small], defaultWidth: 1280, defaultHeight: 800)
                == WindowFrame(x: 0, y: 0, width: 1024, height: 700))
    }

    @Test func noScreensKeepsTheFrame() {
        let frame = WindowFrame(x: 3000, y: 0, width: 1280, height: 800)
        #expect(frame.fitted(onto: [], defaultWidth: 1280, defaultHeight: 800) == frame)
    }
}
