//
//  SequentialClipPlayer.swift
//  AudioClipKit
//
//  Plays a list of `AudioClip`s in order, one after the next. Deliberately
//  simpler than MindHeist's queue engine (no shuffle / pan / EQ / gaps) —
//  sequential walk-through playback is all this needs. Built on AVAudioPlayer:
//  each clip's finish advances to the next; finishing the last fires
//  `onFinishedAll` (hosts use this to log a "review").
//

import SwiftUI
import AVFoundation

public final class SequentialClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    /// Index of the clip currently playing (or last played). Drives the host's
    /// synced image/name display.
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var isPlaying = false
    /// Progress (0...1) within the current clip.
    @Published public private(set) var progress: Double = 0

    /// Fired once when the whole sequence plays to the end.
    public var onFinishedAll: (() -> Void)?
    /// Fired as each clip begins, with its index.
    public var onAdvance: ((Int) -> Void)?

    private var clips: [any AudioClip] = []
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var isPaused = false

    public var clipCount: Int { clips.count }

    public override init() {
        super.init()
        registerInterruptionObserver()
    }

    /// Start playing `clips` from the top. An empty list is a no-op (it does
    /// NOT count as a completed run).
    public func play(_ clips: [any AudioClip]) {
        stop()
        self.clips = clips
        guard !clips.isEmpty else { return }
        AudioSessionConfigurator.configureForPlayback()
        currentIndex = 0
        startClip(at: 0)
    }

    public func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        isPaused = true
        stopProgressTimer()
    }

    public func resume() {
        guard isPaused, let p = player else { return }
        AudioSessionConfigurator.configureForPlayback()
        p.play()
        isPlaying = true
        isPaused = false
        startProgressTimer()
    }

    public func stop() {
        player?.stop()
        player = nil
        stopProgressTimer()
        isPlaying = false
        isPaused = false
        progress = 0
    }

    private func startClip(at index: Int) {
        guard index < clips.count else { finish(); return }
        progress = 0
        // A clip with no audio yet is skipped rather than stalling the walk.
        guard let url = clips[index].audioURL(),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            advance()
            return
        }
        p.delegate = self
        player = p
        p.play()
        isPlaying = true
        isPaused = false
        onAdvance?(index)
        startProgressTimer()
    }

    private func advance() {
        let next = currentIndex + 1
        if next < clips.count {
            currentIndex = next
            startClip(at: next)
        } else {
            finish()
        }
    }

    private func finish() {
        stop()
        onFinishedAll?()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            DispatchQueue.main.async { self.progress = p.currentTime / p.duration }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.advance() }
    }

    // MARK: - Interruptions (calls, Siri, etc.)

    private func registerInterruptionObserver() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        #endif
    }

    #if os(iOS)
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }
    #endif
}
