//
//  AudioSplicer.swift
//  AudioClipKit
//
//  Buffer-level splice-insert: drops a freshly recorded clip into the
//  middle of an existing one at a chosen time, shifting the tail later.
//  Same read/memcpy/write-out shape as AudioTrimmer, but writes to a
//  distinct destination rather than rewriting in place — the caller's
//  "existing" file is typically a temp-materialized copy of a persisted
//  blob, not the source of truth.
//

import AVFoundation
import Accelerate

public struct AudioSplicer {

    public enum SpliceError: LocalizedError {
        case emptyExisting
        case emptyInsertion
        case allocationFailed
        case formatMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .emptyExisting: return "Existing clip has no audio to splice into."
            case .emptyInsertion: return "Recorded insertion clip is empty."
            case .allocationFailed: return "Failed to allocate audio buffer for splice."
            case .formatMismatch(let detail): return "Audio format mismatch: \(detail)"
            }
        }
    }

    /// Splice `insertionURL`'s audio into `existingURL` at `atFrame` (a frame
    /// position in `existingURL`'s own sample rate), writing
    /// `[0, atFrame) + insertion + [atFrame, end)` to `destinationURL`.
    /// Never touches `existingURL`/`insertionURL` — purely additive, nothing
    /// is dropped, only reordered later in the timeline.
    ///
    /// The insertion buffer is converted to the existing clip's format via
    /// `AVAudioConverter` if the two differ (sample rate/channel count) —
    /// defensive, since both inputs come from `AudioClipRecorder`'s fixed
    /// 44.1kHz mono AAC settings today.
    @discardableResult
    public static func splice(existingURL: URL,
                              insertionURL: URL,
                              atFrame: AVAudioFramePosition,
                              destinationURL: URL) throws -> AVAudioFramePosition {
        let existingFile = try AVAudioFile(forReading: existingURL)
        let existingFormat = existingFile.processingFormat
        let existingTotal = AVAudioFramePosition(existingFile.length)
        guard existingTotal > 0 else { throw SpliceError.emptyExisting }

        let insertionFile = try AVAudioFile(forReading: insertionURL)
        guard insertionFile.length > 0 else { throw SpliceError.emptyInsertion }

        guard let existingBuffer = AVAudioPCMBuffer(pcmFormat: existingFormat,
                                                     frameCapacity: AVAudioFrameCount(existingTotal)) else {
            throw SpliceError.allocationFailed
        }
        try existingFile.read(into: existingBuffer)

        let insertionBuffer = try readAndConvert(file: insertionFile, to: existingFormat)

        let insertFrame = max(0, min(atFrame, existingTotal))
        let insertLen = AVAudioFramePosition(insertionBuffer.frameLength)
        let outTotal = existingTotal + insertLen

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: existingFormat,
                                                frameCapacity: AVAudioFrameCount(outTotal)),
              let src = existingBuffer.floatChannelData,
              let ins = insertionBuffer.floatChannelData,
              let dst = outBuffer.floatChannelData else {
            throw SpliceError.allocationFailed
        }
        outBuffer.frameLength = AVAudioFrameCount(outTotal)

        let channelCount = Int(existingFormat.channelCount)
        let head = Int(insertFrame)
        let insCount = Int(insertLen)
        let tail = Int(existingTotal - insertFrame)
        let bytesPerFrame = MemoryLayout<Float>.size
        for c in 0..<channelCount {
            if head > 0 { memcpy(dst[c], src[c], head * bytesPerFrame) }
            if insCount > 0 { memcpy(dst[c] + head, ins[c], insCount * bytesPerFrame) }
            if tail > 0 { memcpy(dst[c] + head + insCount, src[c] + head, tail * bytesPerFrame) }
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: existingFormat.sampleRate,
            AVNumberOfChannelsKey: existingFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("temp_spliced_\(UUID().uuidString).m4a")
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        try outputFile.write(from: outBuffer)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        return outTotal
    }

    /// Reads `file` fully and converts to `targetFormat` if its sample rate
    /// or channel count differs — same single-shot `convert(to:error:)`
    /// idiom as `PlaybackController.renderAnnouncedFile`.
    private static func readAndConvert(file: AVAudioFile, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw SpliceError.allocationFailed
        }
        try file.read(into: raw)

        guard sourceFormat.sampleRate != targetFormat.sampleRate
            || sourceFormat.channelCount != targetFormat.channelCount else {
            return raw
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SpliceError.formatMismatch("cannot convert \(sourceFormat) -> \(targetFormat)")
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(raw.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw SpliceError.allocationFailed
        }
        var conversionError: NSError?
        var consumed = false
        converter.convert(to: converted, error: &conversionError) { _, status in
            guard !consumed else { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return raw
        }
        if let conversionError { throw conversionError }
        return converted
    }
}
