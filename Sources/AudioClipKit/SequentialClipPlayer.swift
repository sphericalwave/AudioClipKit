//
//  SequentialClipPlayer.swift
//  AudioClipKit
//
//  Plays a list of `AudioClip`s in order, one after the next. Deliberately
//  simpler than MindHeist's queue engine (no shuffle / pan / gaps) —
//  sequential walk-through playback is all this needs.
//
//  Built on AVAudioEngine (not AVAudioPlayer) so playback can be *boosted*
//  above the source level: `AVAudioPlayer.volume` and `mainMixerNode.volume`
//  are both capped at 1.0 by iOS, whereas the EQ node's `globalGain` (dB)
//  supports −96…+24 dB — the same gain stage MindHeist uses. Each clip's
//  finish advances to the next; finishing the last fires `onFinishedAll`
//  (hosts use this to log a "review").
//

import SwiftUI
import AVFoundation

public final class SequentialClipPlayer: NSObject, ObservableObject {

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

    /// Linear playback gain. 1.0 = unity (source level); values >1 boost louder
    /// than the recording (routed through the EQ node's `globalGain`). Applied
    /// live — changing it mid-playback takes effect immediately.
    public var gain: Float = 1.0 {
        didSet { boostEQ.globalGain = linearToDB(gain) }
    }

    // AVAudioEngine pipeline: playerNode → boostEQ (gain stage) → mainMixer.
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let boostEQ = AVAudioUnitEQ(numberOfBands: 0)

    private var clips: [any AudioClip] = []
    private var currentFile: AVAudioFile?
    private var currentDuration: Double = 0
    private var progressTimer: Timer?
    private var isPaused = false

    // Bumped whenever the schedule changes (advance / stop). A file-finished
    // completion callback only advances if its captured token still matches —
    // this discards the stray callback that `playerNode.stop()` fires when we
    // tear down or skip to the next clip.
    private var generation = 0

    // Wall-clock progress tracking across pause/resume (an AVAudioPlayerNode has
    // no simple currentTime; MindHeist tracks the same way).
    private var trackStartDate: Date?
    private var accumulatedSeconds: Double = 0

    public var clipCount: Int { clips.count }

    public override init() {
        super.init()
        setupEngine()
        registerInterruptionObserver()
    }

    private func linearToDB(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10(linear) : -96
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(boostEQ)
        engine.connect(playerNode, to: boostEQ, format: nil)
        engine.connect(boostEQ, to: engine.mainMixerNode, format: nil)
        boostEQ.globalGain = linearToDB(gain)
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// Start playing `clips` from the top. An empty list is a no-op (it does
    /// NOT count as a completed run).
    public func play(_ clips: [any AudioClip]) {
        stop()
        self.clips = clips
        guard !clips.isEmpty else { return }
        AudioSessionConfigurator.configureForPlayback()
        startEngine()
        currentIndex = 0
        startClip(at: 0)
    }

    public func pause() {
        guard isPlaying else { return }
        if let start = trackStartDate {
            accumulatedSeconds += Date().timeIntervalSince(start)
            trackStartDate = nil
        }
        playerNode.pause()
        isPlaying = false
        isPaused = true
        stopProgressTimer()
    }

    public func resume() {
        guard isPaused, currentFile != nil else { return }
        AudioSessionConfigurator.configureForPlayback()
        startEngine()
        playerNode.play()
        isPlaying = true
        isPaused = false
        trackStartDate = Date()
        startProgressTimer()
    }

    public func stop() {
        generation += 1
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        stopProgressTimer()
        isPlaying = false
        isPaused = false
        progress = 0
        currentFile = nil
        trackStartDate = nil
        accumulatedSeconds = 0
    }

    private func startClip(at index: Int) {
        guard index < clips.count else { finish(); return }
        progress = 0
        accumulatedSeconds = 0
        trackStartDate = nil

        // A clip with no audio (or an unreadable/zero-length file) is skipped
        // rather than stalling the walk.
        guard let url = clips[index].audioURL(),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0 else {
            advance()
            return
        }

        generation += 1
        let token = generation
        currentFile = file
        currentDuration = Double(file.length) / file.processingFormat.sampleRate

        startEngine()
        playerNode.stop()
        playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.advance()
            }
        }
        playerNode.play()
        isPlaying = true
        isPaused = false
        trackStartDate = Date()
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
            guard let self, self.currentDuration > 0, let start = self.trackStartDate else { return }
            let elapsed = self.accumulatedSeconds + Date().timeIntervalSince(start)
            let p = min(elapsed / self.currentDuration, 1.0)
            DispatchQueue.main.async { self.progress = p }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
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
