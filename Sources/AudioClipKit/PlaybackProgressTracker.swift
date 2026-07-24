//
//  PlaybackProgressTracker.swift
//  AudioClipKit
//
//  Wall-clock progress tracking for the currently-playing clip, across
//  pause/resume cycles. An `AVAudioPlayerNode` has no simple `currentTime`,
//  so progress is derived from elapsed wall-clock time instead.
//

import Foundation

final class PlaybackProgressTracker {
    private(set) var duration: Double = 0
    private var trackStartDate: Date?
    private var accumulatedSeconds: Double = 0

    /// Starts the clock immediately — for a clip that begins playing now.
    func beginTrack(duration: Double) {
        self.duration = duration
        accumulatedSeconds = 0
        trackStartDate = Date()
    }

    /// Records the duration but leaves the clock stopped — for a clip
    /// scheduled to start at a future audio-clock time (a gap). Call
    /// `markStarted()` once it's actually audible.
    func prepareDuration(_ duration: Double) {
        self.duration = duration
        accumulatedSeconds = 0
        trackStartDate = nil
    }

    /// Starts the clock from zero — the scheduled clip has become audible.
    func markStarted() {
        accumulatedSeconds = 0
        trackStartDate = Date()
    }

    func pause() {
        if let start = trackStartDate {
            accumulatedSeconds += Date().timeIntervalSince(start)
            trackStartDate = nil
        }
    }

    func resume() {
        trackStartDate = Date()
    }

    /// True if there's accumulated progress from a previously paused
    /// mid-track clock (as opposed to being paused during a gap).
    var isMidTrack: Bool { accumulatedSeconds > 0 }

    /// Current progress in 0...1, or nil if the clock isn't running.
    var currentProgress: Double? {
        guard duration > 0, let start = trackStartDate else { return nil }
        let elapsed = accumulatedSeconds + Date().timeIntervalSince(start)
        return min(elapsed / duration, 1.0)
    }

    func reset() {
        duration = 0
        trackStartDate = nil
        accumulatedSeconds = 0
    }
}
