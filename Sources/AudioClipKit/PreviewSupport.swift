#if DEBUG
import Foundation

/// Shared sample data for `#Preview` blocks and the README screenshot
/// generator (`ScreenshotGenTests`). DEBUG-only: never in release builds.
enum AudioClipKitSamples {
    /// A smooth, deterministic waveform envelope (0...1) for waveform previews.
    static let peaks: [Float] = (0..<72).map { i in
        let x = Double(i)
        let envelope = 0.35 + 0.65 * abs(cos(x * .pi / 34))
        return Float(abs(sin(x * .pi / 9)) * envelope)
    }

    /// A clip with no audio URL. Preview/screenshot waveforms seed
    /// `WaveformCache` with `peaks` so `StaticWaveformView` has data to draw.
    static let clipID: AnyHashable = "preview-clip"
    static var clip: AudioClipRef { AudioClipRef(clipID: clipID, url: nil) }

    static func seedWaveformCache() {
        WaveformCache.shared.set(clipID, peaks: peaks)
    }
}
#endif
