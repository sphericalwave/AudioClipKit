//
//  AudioNormalizer.swift
//  AudioClipKit
//
//  Generalized from MindHeist (dropped the Idea/Core-Data-coupled
//  `BatchAudioNormalizer`). Pure vDSP RMS normalization of an audio file.
//

import AVFoundation
import Accelerate

public struct AudioNormalizer {

    public enum RMSResult {
        case applied(originalRMSDB: Float, gainDB: Float, peakAfter: Float)
        case skippedNearTarget(currentRMSDB: Float)
        case skippedEmpty
    }

    /// A clip's measured level: average (RMS) and loudest single sample, both
    /// in dBFS, where 0 is full scale and values are negative.
    public struct Loudness: Sendable, Equatable {
        public let rmsDB: Float
        public let peakDB: Float

        public init(rmsDB: Float, peakDB: Float) {
            self.rmsDB = rmsDB
            self.peakDB = peakDB
        }

        /// True when peaks sit close enough to full scale that an RMS-driven
        /// gain gets clamped by the peak ceiling — the recording can't be
        /// raised without limiting. This is why re-running normalization on a
        /// quiet-but-peaky clip appears to do nothing at all.
        public var isPeakLimited: Bool { peakDB > -1.5 }
    }

    /// Measures a clip without modifying it: RMS and peak together, in one
    /// read. Use this for display — `measureRMS` alone can't explain why a
    /// quiet clip refuses to get louder.
    public static func measure(url: URL, excludeSilence: Bool = false) -> Loudness? {
        guard let inputFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = inputFile.processingFormat
        let frameCount = AVAudioFrameCount(inputFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? inputFile.read(into: buffer)) != nil,
              let floatData = buffer.floatChannelData else { return nil }

        let channelCount = Int(format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var start = 0
        var length = frameLength
        if excludeSilence, let bounds = try? AudioTrimmer.detectSilence(url: url) {
            start = Int(bounds.startFrame)
            length = Int(bounds.endFrame - bounds.startFrame)
        }
        guard length > 0 else { return nil }

        var totalSS: Float = 0
        var peak: Float = 0
        for ch in 0..<channelCount {
            var ss: Float = 0
            vDSP_svesq(floatData[ch] + start, 1, &ss, vDSP_Length(length))
            totalSS += ss
            // Peak scans the whole buffer, not just the voiced range: a
            // transient in the lead-in still caps how far gain can go.
            var chPeak: Float = 0
            vDSP_maxmgv(floatData[ch], 1, &chPeak, vDSP_Length(frameLength))
            peak = max(peak, chPeak)
        }
        let rms = sqrt(totalSS / Float(length * channelCount))
        guard rms > 0.0001 else { return nil }
        return Loudness(rmsDB: 20 * log10(rms),
                        peakDB: peak > 0 ? 20 * log10(peak) : -96)
    }

    /// Normalize audio file to a target average (RMS) level in dBFS.
    /// Applies a peak ceiling so the RMS-driven gain never pushes peaks
    /// past `peakCeiling` — protects against clipping on transient-heavy
    /// recordings whose RMS is otherwise far below target.
    /// Files already within `toleranceDB` of the target are left untouched
    /// so re-running doesn't lossy-re-encode every pass.
    ///
    /// With `allowPeakLimiting`, a clip whose peaks would clamp the gain is
    /// raised to target anyway and its peaks soft-limited, instead of being
    /// left quiet. Without it, one loud transient can pin a whole recording
    /// below target permanently — re-running simply recomputes the same clamp.
    @discardableResult
    public static func normalizeRMS(url: URL,
                                    targetRMSDB: Float = -20.0,
                                    toleranceDB: Float = 1.0,
                                    peakCeiling: Float = 0.99,
                                    excludeSilence: Bool = false,
                                    allowPeakLimiting: Bool = false) throws -> RMSResult {
        let inputFile = try AVAudioFile(forReading: url)
        let format = inputFile.processingFormat
        let frameCount = AVAudioFrameCount(inputFile.length)

        guard frameCount > 0 else { return .skippedEmpty }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioNormalizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
        }
        try inputFile.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw NSError(domain: "AudioNormalizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No float data available"])
        }

        let channelCount = Int(format.channelCount)
        let frameLength = Int(buffer.frameLength)

        // RMS is computed over the voiced range when `excludeSilence` is set,
        // so leftover lead/trail dead air doesn't drag the target gain down —
        // but the peak scan (below) stays over the full buffer since a
        // transient outside that range should still cap the gain.
        var rmsStart = 0
        var rmsLength = frameLength
        if excludeSilence, let bounds = try? AudioTrimmer.detectSilence(url: url) {
            rmsStart = Int(bounds.startFrame)
            rmsLength = Int(bounds.endFrame - bounds.startFrame)
        }
        guard rmsLength > 0 else { return .skippedEmpty }

        // Combined RMS across all channels: sqrt(sum_of_squares / total_samples).
        var totalSS: Float = 0
        var peak: Float = 0
        for ch in 0..<channelCount {
            var ss: Float = 0
            vDSP_svesq(floatData[ch] + rmsStart, 1, &ss, vDSP_Length(rmsLength))
            totalSS += ss
            var chPeak: Float = 0
            vDSP_maxmgv(floatData[ch], 1, &chPeak, vDSP_Length(frameLength))
            peak = max(peak, chPeak)
        }
        let totalSamples = Float(rmsLength * channelCount)
        let rms = (totalSamples > 0) ? sqrt(totalSS / totalSamples) : 0

        guard rms > 0.0001 else { return .skippedEmpty }

        let currentDB = 20 * log10(rms)
        if abs(currentDB - targetRMSDB) <= toleranceDB {
            return .skippedNearTarget(currentRMSDB: currentDB)
        }

        let targetRMS = powf(10, targetRMSDB / 20.0)
        let wantedGain = targetRMS / rms
        var gain = wantedGain
        var limiting = false
        if peak > 0 {
            let peakLimit = peakCeiling / peak
            if wantedGain > peakLimit {
                if allowPeakLimiting {
                    // A single transient — a breath pop, a bump on the mic —
                    // otherwise holds the whole recording quiet forever: the
                    // gain gets clamped to ~1x and re-running normalization
                    // changes nothing, no matter how many times it's run.
                    // Take the full RMS gain and soft-limit the peaks.
                    limiting = true
                } else {
                    gain = peakLimit
                }
            }
        }

        for ch in 0..<channelCount {
            vDSP_vsmul(floatData[ch], 1, &gain, floatData[ch], 1, vDSP_Length(frameLength))
        }

        if limiting {
            // tanh soft-clip: transparent well below the ceiling, compressing
            // smoothly as samples approach it, and mathematically incapable
            // of exceeding it. Gentler on speech than hard clipping, which
            // would buzz on every peak it touched.
            var ceiling = peakCeiling
            var inverse = 1 / peakCeiling
            var count = Int32(frameLength)
            for ch in 0..<channelCount {
                vDSP_vsmul(floatData[ch], 1, &inverse, floatData[ch], 1, vDSP_Length(frameLength))
                vvtanhf(floatData[ch], floatData[ch], &count)
                vDSP_vsmul(floatData[ch], 1, &ceiling, floatData[ch], 1, vDSP_Length(frameLength))
            }
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("temp_rms_\(UUID().uuidString).m4a")

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        try outputFile.write(from: buffer)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)

        let peakAfter = limiting ? peakCeiling : peak * gain
        return .applied(originalRMSDB: currentDB, gainDB: 20 * log10(gain), peakAfter: peakAfter)
    }

    /// Read-only RMS measurement. Returns average power in dBFS (negative
    /// value). Nil for empty/silent files.
    public static func measureRMS(url: URL, excludeSilence: Bool = false) -> Float? {
        guard let inputFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = inputFile.processingFormat
        let frameCount = AVAudioFrameCount(inputFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? inputFile.read(into: buffer)) != nil,
              let floatData = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        var start = 0
        var length = Int(buffer.frameLength)
        if excludeSilence, let bounds = try? AudioTrimmer.detectSilence(url: url) {
            start = Int(bounds.startFrame)
            length = Int(bounds.endFrame - bounds.startFrame)
        }
        guard length > 0 else { return nil }
        var totalSS: Float = 0
        for ch in 0..<channelCount {
            var ss: Float = 0
            vDSP_svesq(floatData[ch] + start, 1, &ss, vDSP_Length(length))
            totalSS += ss
        }
        let rms = sqrt(totalSS / Float(length * channelCount))
        guard rms > 0.0001 else { return nil }
        return 20 * log10(rms)
    }
}
