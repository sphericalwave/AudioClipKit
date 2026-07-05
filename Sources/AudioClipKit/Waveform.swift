//
//  Waveform.swift
//  AudioClipKit
//
//  Generalized from MindHeist: the cache is now keyed by `AnyHashable`
//  (was `NSManagedObjectID`) and the view takes any `AudioClip`.
//

import SwiftUI
import AVFoundation

public enum Waveform {
    /// Decode an audio file and downsample to `count` peak values (0...1).
    /// Reads channel 0 only — clips are mono. Max-abs per chunk keeps
    /// transients visible; a final divide by the global max normalizes shape
    /// regardless of recording level.
    public static func peaks(from url: URL, count: Int = 80) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let channelData = buf.floatChannelData else { return nil }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return nil }
        let chunk = max(1, frames / count)
        var peaks: [Float] = []
        peaks.reserveCapacity(count)
        let ch = channelData[0]
        var i = 0
        while i < frames && peaks.count < count {
            let end = min(i + chunk, frames)
            var maxVal: Float = 0
            for j in i..<end {
                let v = abs(ch[j])
                if v > maxVal { maxVal = v }
            }
            peaks.append(maxVal)
            i = end
        }
        // Pad to exact count so layout is stable across rows.
        while peaks.count < count { peaks.append(0) }
        let m = peaks.max() ?? 1
        if m > 0 { for k in peaks.indices { peaks[k] /= m } }
        return peaks
    }
}

/// Tiny in-memory cache. Keyed by the clip's stable id. No eviction — peaks
/// are ~80 floats, even hundreds of rows is well under a megabyte.
public final class WaveformCache: @unchecked Sendable {
    public static let shared = WaveformCache()
    private let queue = DispatchQueue(label: "AudioClipKit.WaveformCache", attributes: .concurrent)
    private var store: [AnyHashable: [Float]] = [:]

    public func get(_ id: AnyHashable) -> [Float]? {
        queue.sync { store[id] }
    }

    public func set(_ id: AnyHashable, peaks: [Float]) {
        queue.async(flags: .barrier) { self.store[id] = peaks }
    }

    /// Drop a cached entry — call after the underlying audio changes
    /// (re-record) so the next render recomputes from the new file.
    public func invalidate(_ id: AnyHashable) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: id) }
    }
}

/// Renders an array of normalized peaks (0...1) as centered vertical bars.
public struct WaveformBars: View {
    public let peaks: [Float]
    public var color: Color

    public init(peaks: [Float], color: Color = .secondary) {
        self.peaks = peaks
        self.color = color
    }

    public var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let n = peaks.count
            let spacing: CGFloat = 1
            let barWidth = max(1, (size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            let mid = size.height / 2
            for (i, p) in peaks.enumerated() {
                let h = max(2, CGFloat(p) * size.height)
                let x = CGFloat(i) * (barWidth + spacing)
                let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(color))
            }
        }
    }
}

/// Static precomputed waveform for a clip. Loads peaks off the main thread on
/// first appearance and caches them. When `progress` is non-nil, draws a
/// vertical playhead line that sweeps left→right across the bars.
public struct StaticWaveformView: View {
    private let clip: any AudioClip
    private let color: Color
    private let barCount: Int
    private let progress: Double?
    @State private var peaks: [Float] = []

    public init(clip: any AudioClip,
                color: Color = .secondary,
                barCount: Int = 80,
                progress: Double? = nil) {
        self.clip = clip
        self.color = color
        self.barCount = barCount
        self.progress = progress
    }

    public var body: some View {
        WaveformBars(peaks: peaks, color: color)
            .overlay(alignment: .leading) {
                if let progress {
                    GeometryReader { geo in
                        let x = geo.size.width * CGFloat(min(max(progress, 0), 1))
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 1.5)
                            .opacity(0.7)
                            .offset(x: x)
                            .animation(.linear(duration: 0.1), value: progress)
                    }
                }
            }
            .task(id: clip.clipID) {
                let id = clip.clipID
                if let cached = WaveformCache.shared.get(id) {
                    peaks = cached
                    return
                }
                guard let url = clip.audioURL() else { return }
                let count = barCount
                let computed = await Task.detached(priority: .utility) {
                    Waveform.peaks(from: url, count: count)
                }.value
                guard let computed else { return }
                WaveformCache.shared.set(id, peaks: computed)
                peaks = computed
            }
    }
}
