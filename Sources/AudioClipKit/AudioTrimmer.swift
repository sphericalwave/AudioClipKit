//
//  AudioTrimmer.swift
//  AudioClipKit
//
//  Moved from MindHeist unchanged apart from `public`. Silence detection +
//  frame-range trim for the recorder pipeline: sits between
//  `AVAudioRecorder.stop()` and `AudioNormalizer.normalizeRMS()` so users see
//  only the spoken portion of their clip in the waveform.
//
//  Lives here so `AudioClipRecorder` can grow a trim phase — its absence was
//  the one thing blocking hosts from retiring their own recorder view models.
//

import AVFoundation
import Accelerate

public struct AudioTrimmer {

    public struct SilenceBounds {
        public var startFrame: AVAudioFramePosition
        public var endFrame: AVAudioFramePosition   // exclusive
        public var totalFrames: AVAudioFramePosition
        public var sampleRate: Double

        public init(startFrame: AVAudioFramePosition,
                    endFrame: AVAudioFramePosition,
                    totalFrames: AVAudioFramePosition,
                    sampleRate: Double) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.totalFrames = totalFrames
            self.sampleRate = sampleRate
        }

        public var duration: Double { Double(totalFrames) / sampleRate }
        public var startSeconds: Double { Double(startFrame) / sampleRate }
        public var endSeconds: Double { Double(endFrame) / sampleRate }
    }

    /// Locate the first and last frame whose local peak exceeds threshold.
    /// Threshold is the louder of `relativeDB` below the file's peak and
    /// `floorDBFS` absolute — so a very quiet recording doesn't trim itself
    /// to nothing chasing a -50dB floor. Bounds default to the full range
    /// when nothing crosses, so callers can always apply them safely.
    public static func detectSilence(url: URL,
                                     relativeDB: Float = -35,
                                     floorDBFS: Float = -50,
                                     minSilenceMS: Int = 120) throws -> SilenceBounds {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            return SilenceBounds(startFrame: 0,
                                 endFrame: AVAudioFramePosition(total),
                                 totalFrames: AVAudioFramePosition(total),
                                 sampleRate: format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            return SilenceBounds(startFrame: 0,
                                 endFrame: AVAudioFramePosition(total),
                                 totalFrames: AVAudioFramePosition(total),
                                 sampleRate: format.sampleRate)
        }
        let frames = Int(buffer.frameLength)
        let ch = channelData[0]

        // Global peak — sets the relative threshold floor.
        var globalPeak: Float = 0
        vDSP_maxmgv(ch, 1, &globalPeak, vDSP_Length(frames))
        guard globalPeak > 0 else {
            return SilenceBounds(startFrame: 0,
                                 endFrame: AVAudioFramePosition(frames),
                                 totalFrames: AVAudioFramePosition(frames),
                                 sampleRate: format.sampleRate)
        }

        let relAmp = globalPeak * powf(10, relativeDB / 20)
        let floorAmp = powf(10, floorDBFS / 20)
        let threshold = max(relAmp, floorAmp)

        // 10ms windows for peak scan — fine enough for speech onsets.
        let windowFrames = max(1, Int(format.sampleRate * 0.01))
        let minSilenceFrames = Int(format.sampleRate * Double(minSilenceMS) / 1000.0)

        // Find first window above threshold; back off by `minSilenceFrames`
        // worth of windows so a soft attack isn't clipped.
        var headWindow = 0
        var w = 0
        while w * windowFrames < frames {
            let start = w * windowFrames
            let end = min(start + windowFrames, frames)
            var peak: Float = 0
            vDSP_maxmgv(ch + start, 1, &peak, vDSP_Length(end - start))
            if peak >= threshold {
                headWindow = w
                break
            }
            w += 1
        }
        let headSilenceWindows = max(0, headWindow - (minSilenceFrames / windowFrames))
        let startFrame = min(frames, headSilenceWindows * windowFrames)

        // Same scan from the tail.
        var tailWindow = (frames + windowFrames - 1) / windowFrames - 1
        var t = tailWindow
        while t >= 0 {
            let start = t * windowFrames
            let end = min(start + windowFrames, frames)
            var peak: Float = 0
            vDSP_maxmgv(ch + start, 1, &peak, vDSP_Length(end - start))
            if peak >= threshold {
                tailWindow = t
                break
            }
            t -= 1
        }
        let tailSilenceWindows = max(0, ((frames + windowFrames - 1) / windowFrames - 1) - tailWindow - (minSilenceFrames / windowFrames))
        let endFrame = max(startFrame,
                           frames - tailSilenceWindows * windowFrames)

        return SilenceBounds(startFrame: AVAudioFramePosition(startFrame),
                             endFrame: AVAudioFramePosition(endFrame),
                             totalFrames: AVAudioFramePosition(frames),
                             sampleRate: format.sampleRate)
    }

    /// Rewrite `url` in place, keeping only frames in `[startFrame, endFrame)`.
    /// No-op when the range already covers the whole file. Output format
    /// matches the recorder (44.1kHz mono AAC); atomic swap via temp file
    /// mirrors `AudioNormalizer`.
    public static func trim(url: URL,
                            startFrame: AVAudioFramePosition,
                            endFrame: AVAudioFramePosition) throws {
        let inputFile = try AVAudioFile(forReading: url)
        let format = inputFile.processingFormat
        let total = AVAudioFramePosition(inputFile.length)
        let start = max(0, min(startFrame, total))
        let end = max(start, min(endFrame, total))
        let keep = AVAudioFrameCount(end - start)

        guard keep > 0 else { return }  // nothing to write; leave file alone
        if start == 0 && end == total { return }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                              frameCapacity: AVAudioFrameCount(total)) else {
            throw NSError(domain: "AudioTrimmer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate read buffer"])
        }
        try inputFile.read(into: inBuffer)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: keep),
              let src = inBuffer.floatChannelData,
              let dst = outBuffer.floatChannelData else {
            throw NSError(domain: "AudioTrimmer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate trim buffer"])
        }
        outBuffer.frameLength = keep
        let channelCount = Int(format.channelCount)
        for c in 0..<channelCount {
            memcpy(dst[c], src[c] + Int(start), Int(keep) * MemoryLayout<Float>.size)
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("temp_trimmed_\(UUID().uuidString).m4a")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        try outputFile.write(from: outBuffer)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}
