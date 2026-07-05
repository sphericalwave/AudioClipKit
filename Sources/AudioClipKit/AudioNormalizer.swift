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

    /// Normalize audio file to a target average (RMS) level in dBFS.
    /// Applies a peak ceiling so the RMS-driven gain never pushes peaks
    /// past `peakCeiling` — protects against clipping on transient-heavy
    /// recordings whose RMS is otherwise far below target.
    /// Files already within `toleranceDB` of the target are left untouched
    /// so re-running doesn't lossy-re-encode every pass.
    @discardableResult
    public static func normalizeRMS(url: URL,
                                    targetRMSDB: Float = -20.0,
                                    toleranceDB: Float = 1.0,
                                    peakCeiling: Float = 0.99) throws -> RMSResult {
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

        // Combined RMS across all channels: sqrt(sum_of_squares / total_samples).
        var totalSS: Float = 0
        var peak: Float = 0
        for ch in 0..<channelCount {
            var ss: Float = 0
            vDSP_svesq(floatData[ch], 1, &ss, vDSP_Length(frameLength))
            totalSS += ss
            var chPeak: Float = 0
            vDSP_maxmgv(floatData[ch], 1, &chPeak, vDSP_Length(frameLength))
            peak = max(peak, chPeak)
        }
        let totalSamples = Float(frameLength * channelCount)
        let rms = (totalSamples > 0) ? sqrt(totalSS / totalSamples) : 0

        guard rms > 0.0001 else { return .skippedEmpty }

        let currentDB = 20 * log10(rms)
        if abs(currentDB - targetRMSDB) <= toleranceDB {
            return .skippedNearTarget(currentRMSDB: currentDB)
        }

        let targetRMS = powf(10, targetRMSDB / 20.0)
        var gain = targetRMS / rms
        if peak > 0 {
            let peakLimit = peakCeiling / peak
            gain = min(gain, peakLimit)
        }

        for ch in 0..<channelCount {
            vDSP_vsmul(floatData[ch], 1, &gain, floatData[ch], 1, vDSP_Length(frameLength))
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

        return .applied(originalRMSDB: currentDB, gainDB: 20 * log10(gain), peakAfter: peak * gain)
    }

    /// Read-only RMS measurement. Returns average power in dBFS (negative
    /// value). Nil for empty/silent files.
    public static func measureRMS(url: URL) -> Float? {
        guard let inputFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = inputFile.processingFormat
        let frameCount = AVAudioFrameCount(inputFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? inputFile.read(into: buffer)) != nil,
              let floatData = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var totalSS: Float = 0
        for ch in 0..<channelCount {
            var ss: Float = 0
            vDSP_svesq(floatData[ch], 1, &ss, vDSP_Length(frameLength))
            totalSS += ss
        }
        let rms = sqrt(totalSS / Float(frameLength * channelCount))
        guard rms > 0.0001 else { return nil }
        return 20 * log10(rms)
    }
}
