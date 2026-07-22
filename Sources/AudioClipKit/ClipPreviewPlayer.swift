//
//  ClipPreviewPlayer.swift
//  AudioClipKit
//
//  Generalized from MindHeist's `AudioPreviewVm`. Single-clip play/pause
//  preview built on AVAudioPlayer, for the component editor.
//

import SwiftUI
import AVFoundation

public final class ClipPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var loadedID: AnyHashable?
    private var progressTimer: Timer?
    private let normalizeBeforePlay: Bool

    /// `normalizeBeforePlay` runs `AudioNormalizer.normalizeRMS` on the clip
    /// before its first play, so quiet recordings preview at a consistent
    /// level. Note this rewrites the file at `audioURL()` — hosts backed by a
    /// temp materialization (blob → temp file) can enable it freely, while
    /// hosts handing back a URL they own should leave it off.
    ///
    /// Defaults to off: silently re-encoding a host's file is not a reasonable
    /// default. MindHeist enables it to preserve the behavior its own
    /// `AudioPreviewVm` had.
    public init(normalizeBeforePlay: Bool = false) {
        self.normalizeBeforePlay = normalizeBeforePlay
        super.init()
    }

    /// Toggle playback of `clip`. Resumes if the same clip is already loaded,
    /// otherwise loads and plays from the top.
    public func toggle(_ clip: any AudioClip) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            stopProgressTimer()
            return
        }
        AudioSessionConfigurator.configureForPlayback()

        if let p = player, loadedID == clip.clipID {
            p.play()
            isPlaying = true
            startProgressTimer()
            return
        }
        guard let url = clip.audioURL() else { return }
        let id = clip.clipID

        guard normalizeBeforePlay else {
            startPlaying(url: url, id: id)
            return
        }
        // Normalization decodes and re-encodes the whole file — off the main
        // thread, then back to start playback.
        Task.detached(priority: .userInitiated) {
            do { try AudioNormalizer.normalizeRMS(url: url) }
            catch { AudioSessionConfigurator.log("preview normalize failed: \(error.localizedDescription)") }
            await MainActor.run { [weak self] in
                self?.startPlaying(url: url, id: id)
            }
        }
    }

    private func startPlaying(url: URL, id: AnyHashable) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        player = p
        loadedID = id
        progress = 0
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    public func stop() {
        player?.stop()
        player = nil
        loadedID = nil
        isPlaying = false
        progress = 0
        stopProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            DispatchQueue.main.async { self.progress = p.currentTime / p.duration }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.progress = 0
            self.player?.currentTime = 0
            self.stopProgressTimer()
        }
    }
}
