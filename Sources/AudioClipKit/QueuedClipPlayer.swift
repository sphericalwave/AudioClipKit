//
//  QueuedClipPlayer.swift
//  AudioClipKit
//
//  Plays a queue of clips one after another with shuffle, repeat,
//  fixed-or-randomized inter-track gaps (with IO-buffer widening for long
//  ones), stereo-pan randomization, and periodic re-injection of a
//  "priority" clip (e.g. a script the host wants surfaced every N plays).
//
//  Deliberately more capable than `SequentialClipPlayer` — that one is for
//  simple walk-through playback; this is MindHeist's original queue engine,
//  generalized over `AudioClip`. Persistence-agnostic: the kit does not touch
//  any store — use `onClipFinished` to run host-side side effects (increment
//  play counts, save a context, etc).
//

import AVFoundation
import Combine

public final class QueuedClipPlayer<Clip: AudioClip>: ObservableObject {

    @Published public private(set) var currentClip: Clip?
    /// Lags `currentClip` during a gap: `currentClip` is reassigned to the
    /// next clip as soon as it's scheduled (still silent, waiting out the
    /// gap), while this only flips once that clip is actually audible. UI
    /// that shows "what's playing" should read this, not `currentClip`.
    @Published public private(set) var nowPlayingClip: Clip?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPaused = false
    /// Current clip playback progress, 0...1.
    @Published public private(set) var progress: Double = 0
    /// When the next clip is scheduled to start (set during the gap between
    /// clips).
    @Published public private(set) var nextTrackAt: Date?
    @Published public private(set) var currentEar: String = "—"

    public var volume: Float = 1.0 {
        didSet { chain.gain = volume }
    }

    /// Fired once a clip finishes playing. Run your own side effects here —
    /// the kit does not persist anything itself.
    public var onClipFinished: ((Clip) -> Void)?
    /// Diagnostic sink. Assign to route logs into a host's logger.
    public var log: (String) -> Void = { _ in } {
        didSet { sessionObserver.log = log }
    }

    private let chain = AudioEngineChain()
    private let gapScheduler: GapScheduler
    private let progressTracker = PlaybackProgressTracker()
    private let sessionObserver = PlaybackSessionObserver()

    private var allClips: [Clip]
    private var stack: [Clip]
    private let isRepeating: Bool
    private let randomMode: Bool
    private let randomEar: Bool
    private let priorityClip: Clip?
    private let priorityInterval: Int
    private var playsSincePriority = 0
    private let repeatPerClip: Int
    private var currentClipPlayCount = 0

    private var currentFile: AVAudioFile?
    private var currentDuration: Double = 0
    private var progressTimer: Timer?
    private var gapWaiting = false

    public init(
        clips: [Clip],
        delay: Double,
        isRepeating: Bool,
        randomMode: Bool = true,
        randomGaps: Bool = false,
        randomGapLow: Double = 3,
        randomGapHigh: Double = 15,
        randomEar: Bool = false,
        priorityClip: Clip? = nil,
        priorityInterval: Int = 7,
        repeatPerClip: Int = 1
    ) {
        self.allClips = clips
        self.stack = randomMode ? clips.shuffled() : clips
        self.isRepeating = isRepeating
        self.randomMode = randomMode
        self.randomEar = randomEar
        self.priorityClip = priorityClip
        self.priorityInterval = priorityInterval
        self.repeatPerClip = repeatPerClip
        self.gapScheduler = GapScheduler(delay: delay, randomGaps: randomGaps,
                                          randomGapLow: randomGapLow, randomGapHigh: randomGapHigh)
        wireSessionObserver()
    }

    deinit {
        progressTimer?.invalidate()
    }

    // MARK: - Transport

    public func play() {
        // Don't start the engine here — playClip() does it and needs to see
        // engine.isRunning still false to detect a cold start.
        playNextValid()
        isPlaying = true
    }

    public func stop() {
        stopProgressTimer()
        chain.fullStop()
        gapScheduler.cancelPending()
        currentFile = nil
        isPlaying = false
        isPaused = false
        currentClip = nil
        nowPlayingClip = nil
        nextTrackAt = nil
        progressTracker.reset()
    }

    public func pause() {
        gapScheduler.cancelPending()
        if nextTrackAt != nil {
            // Paused during a gap: cancel scheduled audio, push clip back to queue.
            if let clip = currentClip { stack.insert(clip, at: 0) }
            chain.playerNode.stop()
            currentFile = nil
            currentClip = nil
            gapWaiting = false
        } else if chain.playerNode.isPlaying {
            progressTracker.pause()
            chain.playerNode.pause()
        }
        nextTrackAt = nil
        isPaused = true
        isPlaying = false
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        isPlaying = true
        if currentFile != nil, progressTracker.isMidTrack {
            chain.start(onError: { [weak self] e in self?.log("[engine] start failed: \(e)") })
            chain.playerNode.play()
            progressTracker.resume()
            startProgressTimer()
        } else {
            // Paused during a gap or no current clip — jump to next.
            playNextValid()
        }
    }

    public func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Removes queued (not-yet-played) clips matching `predicate` — e.g. when
    /// the host deletes the underlying record out from under a running queue.
    public func removeFromQueue(where predicate: (Clip) -> Bool) {
        stack.removeAll(where: predicate)
    }

    /// Adds `clip` to both the persistent pool and the currently running
    /// queue, so it's eligible for the next pick immediately rather than
    /// waiting for the pool to next reshuffle — e.g. when the host records a
    /// new clip while a session is already playing.
    public func addToQueue(_ clip: Clip) {
        allClips.append(clip)
        let index = randomMode ? Int.random(in: 0...stack.count) : stack.count
        stack.insert(clip, at: index)
    }

    /// Combined player + engine state, for a host's diagnostic log.
    public var diagnosticDescription: String {
        let nextTrackDesc = nextTrackAt.map { String(format: "%.1fs", $0.timeIntervalSinceNow) } ?? "nil"
        var parts: [String] = []
        parts.append("isPlaying=\(isPlaying)")
        parts.append("isPaused=\(isPaused)")
        parts.append("gapWaiting=\(gapWaiting)")
        parts.append("engine.running=\(chain.engine.isRunning)")
        parts.append("node.playing=\(chain.playerNode.isPlaying)")
        parts.append("currentDuration=\(currentDuration)")
        parts.append("nextTrackAt=\(nextTrackDesc)")
        return parts.joined(separator: " ")
    }

    // MARK: - Queue walk

    private func consumeNextPlayable() -> Clip? {
        if isRepeating && stack.isEmpty {
            stack = randomMode ? allClips.shuffled() : allClips
        }
        while !stack.isEmpty {
            let item = stack.removeFirst()
            guard let url = item.audioURL(), FileManager.default.fileExists(atPath: url.path) else {
                log("Skipping clip with no readable audio")
                continue
            }
            return item
        }
        return nil
    }

    private func playNextValid() {
        if let clip = consumeNextPlayable() {
            currentClip = clip
            nowPlayingClip = clip
            currentClipPlayCount = 1
            playClip(clip)
        } else {
            log("No valid audio found in queue")
            stop()
        }
    }

    private func playClip(_ clip: Clip) {
        stopProgressTimer()
        chain.playerNode.stop()
        currentFile = nil
        nextTrackAt = nil
        progressTracker.reset()

        guard let url = clip.audioURL() else {
            playNextValid()
            return
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            if duration == 0 {
                playNextValid()
                return
            }
            currentFile = file
            currentDuration = duration
            // A fresh (or just-fully-stopped) engine means the audio session
            // was just activated too — the very first render right after
            // activation can be silent or cut out after a fraction of a
            // second because the output route hasn't finished settling yet
            // (only a manual pause/resume "fixed" it before this). Give a
            // cold start a brief beat before pushing real audio; an
            // already-running engine (mid-session track-to-track) skips it.
            let coldStart = !chain.engine.isRunning
            chain.start(onError: { [weak self] e in self?.log("[engine] start failed: \(e)") })
            let beginPlayback: () -> Void = { [weak self] in
                guard let self else { return }
                // The warm-up wait can span a route negotiation (e.g.
                // Bluetooth A2DP) long/disruptive enough that the engine
                // auto-stops itself in the meantime — re-verify right at the
                // play call instead of trusting the state from above.
                self.chain.start(onError: { e in self.log("[engine] restart before play failed: \(e)") })
                self.applyNextPan()
                self.chain.playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { self?.clipDidFinishPlaying() }
                }
                self.chain.playerNode.play()
                self.progressTracker.beginTrack(duration: duration)
                self.startProgressTimer()
            }
            if coldStart {
                log("cold engine start — delaying first playback to let route settle")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: beginPlayback)
            } else {
                beginPlayback()
            }
        } catch {
            log("AVAudioFile init failed (\(url.lastPathComponent)): \(error.localizedDescription)")
            playNextValid()
        }
    }

    private func clipDidFinishPlaying() {
        if let clip = currentClip {
            onClipFinished?(clip)
        }

        // Priority-clip injection: count non-priority plays; insert at front
        // when the threshold is hit.
        if let priority = priorityClip, priorityInterval > 0 {
            if currentClip?.clipID != priority.clipID {
                playsSincePriority += 1
                if playsSincePriority >= priorityInterval {
                    stack.insert(priority, at: 0)
                    playsSincePriority = 0
                }
            }
        }

        guard isPlaying, !isPaused else { return }

        let gap = gapScheduler.nextGapDelay()
        let fireAt = Date().addingTimeInterval(gap)
        log("gap scheduled: gap=\(gap)s")

        // Audio-driven gap: render actual silence for the gap, then the next
        // clip, back-to-back on the player node — so the node never goes idle.
        // A previous approach scheduled the next clip at a future audio-clock
        // time, leaving a silent hole; iOS suspends a backgrounded app whose
        // audio output is idle even when the engine reports "running" and the
        // node "playing" (observed on-device: backgrounded mid-gap, the
        // process was suspended and the future-scheduled clip never fired,
        // killing playback until the app was reopened). Continuously
        // scheduled silence keeps the background-audio assertion alive across
        // the gap; the real clip is queued right behind it.
        let nextClip: Clip?
        if repeatPerClip > 1, let clip = currentClip, currentClipPlayCount < repeatPerClip {
            currentClipPlayCount += 1
            nextClip = clip
        } else {
            currentClipPlayCount = 1
            nextClip = consumeNextPlayable()
        }
        if let nextClip, let url = nextClip.audioURL() {
            do {
                let nextFile = try AVAudioFile(forReading: url)
                let nextDuration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
                if nextDuration == 0 {
                    DispatchQueue.main.async { [weak self] in self?.playNextValid() }
                    return
                }
                stopProgressTimer()
                chain.playerNode.stop()
                currentFile = nextFile
                currentDuration = nextDuration
                currentClip = nextClip
                nextTrackAt = fireAt
                progressTracker.prepareDuration(nextDuration)

                applyNextPan()
                if let silence = Self.makeSilenceBuffer(seconds: gap,
                                                        format: chain.playerNode.outputFormat(forBus: 0)) {
                    chain.playerNode.scheduleBuffer(silence, completionHandler: nil)
                }
                chain.playerNode.scheduleFile(nextFile, at: nil,
                                        completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { self?.clipDidFinishPlaying() }
                }
                chain.playerNode.play()
                gapWaiting = true
                startProgressTimer()

                gapScheduler.widenIOBufferIfWorthwhile(forGap: gap)
                return
            } catch {
                log("chain AVAudioFile init failed (\(url.lastPathComponent)): \(error.localizedDescription) — falling back to timer")
                stack.insert(nextClip, at: 0)
            }
        }

        // Fallback: end of non-repeating queue, or next file's init failed.
        gapScheduler.scheduleFallback(after: gap) { [weak self] in
            guard let self else { return }
            let lateness = Date().timeIntervalSince(fireAt)
            self.log("gap fired (fallback): lateness=\(lateness)s isPlaying=\(self.isPlaying) isPaused=\(self.isPaused)")
            guard self.isPlaying, !self.isPaused else { return }
            self.playNextValid()
        }
        nextTrackAt = fireAt
        gapWaiting = true
    }

    // MARK: - Gap silence

    /// A zero-filled (silent) PCM buffer `seconds` long in `format`, used to
    /// fill an inter-clip gap with actually-rendered silence so the player
    /// node stays active and iOS keeps the background-audio assertion alive.
    /// Length is exactly `seconds * sampleRate` frames so the gap timing is
    /// unchanged from the old future-schedule approach.
    static func makeSilenceBuffer(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, (seconds * format.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        // AVAudioPCMBuffer's backing memory isn't guaranteed zeroed — a
        // non-zero gap would render as audible noise. Zero every channel.
        if let ch = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                memset(ch[c], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        return buffer
    }

    // MARK: - Pan

    private func applyNextPan() {
        guard randomEar else {
            chain.playerNode.pan = 0
            return
        }
        let pan: Float = [-1.0, 0.0, 1.0].randomElement() ?? 0
        chain.playerNode.pan = pan
        switch pan {
        case -1.0: currentEar = "Left"
        case  1.0: currentEar = "Right"
        default:   currentEar = "Both"
        }
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }

            if self.gapWaiting {
                // Detect when scheduled audio has actually started playing.
                guard let fireAt = self.nextTrackAt, Date() >= fireAt else { return }
                self.gapWaiting = false
                self.progressTracker.markStarted()
                // Gap is over — the scheduled clip is now playing. Clear the
                // countdown target so the timer disappears instead of
                // freezing at "0s" for the whole clip.
                DispatchQueue.main.async {
                    self.nextTrackAt = nil
                    self.nowPlayingClip = self.currentClip
                }
            }

            guard let prog = self.progressTracker.currentProgress else { return }
            DispatchQueue.main.async { self.progress = prog }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = 0
    }

    // MARK: - Session observer wiring

    private func wireSessionObserver() {
        sessionObserver.isPlaying = { [weak self] in self?.isPlaying ?? false }
        sessionObserver.isPaused = { [weak self] in self?.isPaused ?? false }
        sessionObserver.isNodePlaying = { [weak self] in self?.chain.playerNode.isPlaying ?? false }

        sessionObserver.onRouteChangeShouldPause = { [weak self] in
            DispatchQueue.main.async { self?.pause() }
        }
        sessionObserver.onInterruptionBegan = { [weak self] in
            DispatchQueue.main.async { self?.pause() }
        }
        sessionObserver.onInterruptionEndedShouldResume = { [weak self] in
            // Not just reactivate() — a host that deactivates the session on
            // every pause (to let other apps un-duck) leaves the category at
            // whatever deactivate() set (e.g. `.ambient`), which has no
            // background-audio entitlement. Re-apply the playback category
            // itself, exactly like the manual-resume path does, or playback
            // looks fine in the foreground and then silently drops the
            // instant the app backgrounds.
            AudioSessionConfigurator.configureForPlayback()
            DispatchQueue.main.async { self?.resume() }
        }
        sessionObserver.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            self.log("mediaServicesWereReset — rebuilding audio stack")
            self.chain.fullStop()
            AudioSessionConfigurator.configureForPlayback()
            if self.isPlaying {
                DispatchQueue.main.async { self.playNextValid() }
            }
        }
        sessionObserver.onDidEnterBackground = { [weak self] in
            guard let self else { return }
            // Snapshot player + gap state at the exact background transition:
            // if audio dies on backgrounding, this shows whether we went
            // background mid-clip (node.playing, no nextTrackAt) or mid-gap
            // (gapWaiting, nextTrackAt set — only silence scheduled ahead,
            // which iOS may not treat as active audio).
            self.log("didEnterBackground \(self.diagnosticDescription)")
            self.stopProgressTimer()
        }
        sessionObserver.onWillEnterForeground = { [weak self] in
            guard let self else { return }
            // Pair with the background snapshot: compare state here to catch
            // audio silently dropped while suspended (e.g. engine.running or
            // node.playing flipped false across the background window).
            self.log("willEnterForeground \(self.diagnosticDescription)")
            if self.isPlaying { self.startProgressTimer() }
        }
    }
}
