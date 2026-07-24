//
//  GapScheduler.swift
//  AudioClipKit
//
//  Picks the pause length between queued clips (fixed or randomized via
//  `GapSampler`) and owns the fallback dispatch timer used when the next
//  clip couldn't be scheduled on the audio clock. Also widens/restores the
//  audio session's IO buffer duration around long gaps, trading wakeup rate
//  for latency while nothing is about to play.
//

import Foundation

final class GapScheduler {
    private let fixedDelay: Double
    private let randomGaps: Bool
    private let randomGapLow: Double
    private let randomGapHigh: Double
    private var lastGapBucket: Int = -1

    // Minimum gap length worth widening the IO buffer for — below this, the
    // wakeup-rate savings don't justify two IO reconfigurations.
    private let widenThreshold: Double = 3.0
    // How long before the next track fires to restore the tight IO buffer,
    // so playback attack stays clean.
    private let restoreLeadTime: Double = 1.5

    private var pendingFallback: DispatchWorkItem?
    private var pendingBufferRestore: DispatchWorkItem?
    private var savedIOBufferDuration: TimeInterval = 0

    init(delay: Double, randomGaps: Bool, randomGapLow: Double, randomGapHigh: Double) {
        self.fixedDelay = delay
        self.randomGaps = randomGaps
        self.randomGapLow = randomGapLow
        self.randomGapHigh = randomGapHigh
    }

    func nextGapDelay() -> Double {
        guard randomGaps else { return fixedDelay }
        let lo = min(randomGapLow, randomGapHigh)
        let hi = max(randomGapLow, randomGapHigh)
        return GapSampler.next(lo: lo, hi: hi, lastBucket: &lastGapBucket)
    }

    /// Schedules `work` to fire after `gap` seconds as a fallback path (used
    /// when the caller couldn't schedule the next clip on the audio clock).
    /// Replaces any previously pending fallback.
    func scheduleFallback(after gap: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        pendingFallback?.cancel()
        pendingFallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: item)
    }

    /// Widens the IO buffer for a gap longer than the threshold, and
    /// schedules its restore shortly before the next track is due to start.
    func widenIOBufferIfWorthwhile(forGap gap: Double) {
        guard gap > widenThreshold else { return }
        pendingBufferRestore?.cancel()
        savedIOBufferDuration = AudioSessionConfigurator.widenIOBufferForGap()
        let restoreDelay = max(gap - restoreLeadTime, 0)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            AudioSessionConfigurator.restoreIOBufferDuration(self.savedIOBufferDuration)
            self.savedIOBufferDuration = 0
        }
        pendingBufferRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    /// Cancels any pending fallback dispatch and buffer-restore, and restores
    /// the IO buffer immediately. Call on pause/stop.
    func cancelPending() {
        pendingFallback?.cancel()
        pendingFallback = nil
        pendingBufferRestore?.cancel()
        pendingBufferRestore = nil
        AudioSessionConfigurator.restoreIOBufferDuration(savedIOBufferDuration)
        savedIOBufferDuration = 0
    }
}
