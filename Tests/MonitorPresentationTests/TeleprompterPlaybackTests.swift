import Testing

@testable import MonitorPresentation

struct TeleprompterPlaybackTests {
    @Test func pauseResumeAndManualScrollRetainTheReadingPosition() {
        var playback = TeleprompterPlayback()
        playback.play()
        playback.advance(elapsed: 2, speed: 30, end: 500)
        #expect(playback.position == 60)
        playback.pause()
        playback.advance(elapsed: 100, speed: 30, end: 500)
        #expect(playback.position == 60)
        playback.play()
        playback.advance(elapsed: 0.5, speed: 60, end: 500)
        #expect(playback.position == 90)
        playback.seek(to: 240)
        #expect(!playback.isPlaying)
        playback.play()
        playback.advance(elapsed: 1, speed: 30, end: 500)
        #expect(playback.position == 270)
    }

    @Test func reachingTheEndStopsAndResetReturnsToTheBeginning() {
        var playback = TeleprompterPlayback()
        playback.play()
        playback.advance(elapsed: 10, speed: 30, end: 125)
        #expect(playback.position == 125)
        #expect(!playback.isPlaying)
        playback.reset()
        #expect(playback.position == 0)
        #expect(!playback.isPlaying)
        playback.play()
        playback.advance(elapsed: 1, speed: 30, end: 0)
        #expect(playback.position == 0)
        #expect(!playback.isPlaying)
    }
}
