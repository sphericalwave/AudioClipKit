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
