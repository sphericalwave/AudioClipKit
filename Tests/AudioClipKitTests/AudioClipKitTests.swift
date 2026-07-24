import XCTest
import AVFoundation
@testable import AudioClipKit

final class AudioClipKitTests: XCTestCase {

    // MARK: - Helpers

    /// Write a mono sine-wave m4a to a temp file and return its URL.
    private func makeSineFile(seconds: Double = 0.5,
                              frequency: Double = 440,
                              amplitude: Float = 0.5,
                              sampleRate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * sinf(Float(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
        try file.write(from: buf)
        return url
    }

    /// Silence → tone → silence, for exercising trim boundaries.
    private func makeSineFileWithSilence(leadSilence: Double,
                                         tone: Double,
                                         trailSilence: Double,
                                         frequency: Double = 440,
                                         amplitude: Float = 0.5,
                                         sampleRate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let total = leadSilence + tone + trailSilence
        let frames = AVAudioFrameCount(total * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        let toneStart = Int(leadSilence * sampleRate)
        let toneEnd = Int((leadSilence + tone) * sampleRate)
        for i in 0..<Int(frames) {
            ch[i] = (i >= toneStart && i < toneEnd)
                ? amplitude * sinf(Float(2.0 * .pi * frequency * Double(i) / sampleRate))
                : 0
        }
        try file.write(from: buf)
        return url
    }

    private struct DummyClip: AudioClip {
        let clipID: AnyHashable
        let url: URL?
        func audioURL() -> URL? { url }
    }

    // MARK: - Waveform

    func testPeaksReturnsExactCount() throws {
        let url = try makeSineFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try XCTUnwrap(Waveform.peaks(from: url, count: 64))
        XCTAssertEqual(peaks.count, 64)
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(peaks.max() ?? 0, 1, accuracy: 0.0001, "peaks are normalized to a max of 1")
    }

    // MARK: - Normalizer

    func testNormalizeThenSkipNearTarget() throws {
        let url = try makeSineFile(amplitude: 0.05) // quiet → needs gain
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try AudioNormalizer.normalizeRMS(url: url)
        if case .applied = first {} else {
            XCTFail("quiet input should have been normalized, got \(first)")
        }
        // Second pass: already near target → skipped, no re-encode.
        let second = try AudioNormalizer.normalizeRMS(url: url)
        if case .skippedNearTarget = second {} else {
            XCTFail("already-normalized input should be skipped, got \(second)")
        }
        // Still decodable afterwards.
        XCTAssertNotNil(try? AVAudioFile(forReading: url))
    }

    // MARK: - AudioClipRecorder

    @MainActor
    func testPauseResumeGatedByPhase() {
        // Exercises only the phase guards, not real AVAudioRecorder I/O —
        // CI runners have no microphone, so `start()` isn't tested here.
        let recorder = AudioClipRecorder()
        XCTAssertEqual(recorder.phase, .ready)
        recorder.pause()
        XCTAssertEqual(recorder.phase, .ready, "pause() before recording must not change phase")
        recorder.resume()
        XCTAssertEqual(recorder.phase, .ready, "resume() while ready must not change phase")
    }

    // MARK: - AudioSessionConfigurator

    #if os(iOS)
    func testDuckedPlaybackOptionsDuckAndMix() {
        let opts = AudioSessionConfigurator.duckedPlaybackOptions
        XCTAssertTrue(opts.contains(.duckOthers), "ducked playback must lower other apps' audio")
        XCTAssertTrue(opts.contains(.mixWithOthers), "must mix rather than interrupt")
    }

    func testConfigureForPlaybackSetsExpectedCategory() {
        AudioSessionConfigurator.configureForPlayback()
        let s = AVAudioSession.sharedInstance()
        XCTAssertEqual(s.category, .playback)
        XCTAssertTrue(s.categoryOptions.contains(.mixWithOthers))
    }

    func testVerifyAndCorrectReappliesDriftedPlaybackCategory() throws {
        AudioSessionConfigurator.configureForPlayback()
        // Simulate external drift: something else repossessed the category.
        try AVAudioSession.sharedInstance().setCategory(.ambient)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        AudioSessionConfigurator.verifyAndCorrect()

        let s = AVAudioSession.sharedInstance()
        XCTAssertEqual(s.category, .playback, "verifyAndCorrect must restore the intended category")
        XCTAssertTrue(s.categoryOptions.contains(.mixWithOthers))
    }

    func testVerifyAndCorrectReappliesDriftedDuckedPlaybackOptions() throws {
        AudioSessionConfigurator.configureForDuckedPlayback()
        // Drop back to plain mixing, losing the duck option.
        try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.duckOthers))

        AudioSessionConfigurator.verifyAndCorrect()

        let opts = AVAudioSession.sharedInstance().categoryOptions
        XCTAssertTrue(opts.contains(.duckOthers), "verifyAndCorrect must restore ducking for a ducked-playback intent")
        XCTAssertTrue(opts.contains(.mixWithOthers))
    }

    func testVerifyAndCorrectIsNoOpWhenIdle() throws {
        AudioSessionConfigurator.deactivate() // currentIntent -> .idle
        try AVAudioSession.sharedInstance().setCategory(.ambient)

        AudioSessionConfigurator.verifyAndCorrect()

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient,
                       "idle intent has nothing to enforce; verifyAndCorrect must not touch the session")
    }
    #endif

    // MARK: - AudioTrimmer

    func testDetectSilenceFindsTheLoudRegion() throws {
        // 0.25s silence, 0.5s tone, 0.25s silence.
        let url = try makeSineFileWithSilence(leadSilence: 0.25, tone: 0.5, trailSilence: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }

        let bounds = try AudioTrimmer.detectSilence(url: url)
        XCTAssertGreaterThan(bounds.startSeconds, 0.1,
                             "should skip most of the leading silence")
        XCTAssertLessThan(bounds.startSeconds, 0.3,
                          "should not eat into the tone")
        XCTAssertGreaterThan(bounds.endSeconds, 0.6,
                             "should keep the whole tone")
        XCTAssertLessThan(bounds.endSeconds, bounds.duration,
                          "should drop some trailing silence")
    }

    func testDetectSilenceOnFullySilentFileReturnsFullRange() throws {
        let url = try makeSineFile(seconds: 0.3, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let bounds = try AudioTrimmer.detectSilence(url: url)
        XCTAssertEqual(bounds.startFrame, 0)
        XCTAssertEqual(bounds.endFrame, bounds.totalFrames,
                       "a silent file must trim to the full range, never to nothing")
    }

    func testTrimShortensTheFile() throws {
        let url = try makeSineFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try AVAudioFile(forReading: url).length

        try AudioTrimmer.trim(url: url, startFrame: 0, endFrame: before / 2)

        let after = try AVAudioFile(forReading: url).length
        XCTAssertLessThan(after, before)
        XCTAssertGreaterThan(after, 0, "trimmed file must still be playable")
    }

    func testTrimIsNoOpForFullRange() throws {
        let url = try makeSineFile(seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try AVAudioFile(forReading: url).length

        try AudioTrimmer.trim(url: url, startFrame: 0, endFrame: before)

        XCTAssertEqual(try AVAudioFile(forReading: url).length, before,
                       "full-range trim must not re-encode")
    }

    // MARK: - GapSampler

    func testGapSamplerStaysInRangeAndAvoidsRepeatBuckets() {
        var lastBucket = -1
        var buckets: [Int] = []
        for _ in 0..<200 {
            let previous = lastBucket
            let gap = GapSampler.next(lo: 4, hi: 20, lastBucket: &lastBucket)
            XCTAssertGreaterThanOrEqual(gap, 4)
            XCTAssertLessThan(gap, 20)
            XCTAssertNotEqual(lastBucket, previous,
                              "must not pick the same bucket twice in a row")
            buckets.append(lastBucket)
        }
        XCTAssertEqual(Set(buckets).count, 4, "all four buckets should get used")
    }

    func testGapSamplerDegenerateRangeReturnsLo() {
        var lastBucket = -1
        XCTAssertEqual(GapSampler.next(lo: 7, hi: 7, lastBucket: &lastBucket), 7)
        XCTAssertEqual(GapSampler.next(lo: 7, hi: 3, lastBucket: &lastBucket), 7)
    }

    // MARK: - SequentialClipPlayer

    @MainActor
    func testEmptySequenceIsNoOp() {
        let player = SequentialClipPlayer()
        var finished = false
        player.onFinishedAll = { finished = true }
        player.play([])
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(finished, "empty sequence must not count as a completed run")
    }

    @MainActor
    func testSequenceOfAudiolessClipsCompletes() {
        let player = SequentialClipPlayer()
        let exp = expectation(description: "finished")
        player.onFinishedAll = { exp.fulfill() }
        // Clips with no audio are skipped; the run should still complete.
        player.play([
            DummyClip(clipID: 1, url: nil),
            DummyClip(clipID: 2, url: nil),
        ])
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(player.isPlaying)
    }
}
