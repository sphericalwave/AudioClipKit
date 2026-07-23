//
//  AudioSessionConfigurator.swift
//  AudioClipKit
//
//  Generalized from MindHeist. Static AVAudioSession helpers. The only host
//  coupling — MindHeist's `ErrorLog.shared` — is replaced by an injectable
//  `log` closure (defaults to `print`).
//

import AVFoundation

public enum AudioSessionConfigurator {

    /// Diagnostic sink. Assign to route session logs into a host's logger.
    public static var log: (String) -> Void = { print("[AudioSession] \($0)") }

    /// Playback default. `.playback` is the only category that reliably honors
    /// `.mixWithOthers` against the system music apps — `.playAndRecord` claims
    /// the input route on activation and pauses other producers (Spotify,
    /// Music) even with `.mixWithOthers` set. We swap to `.playAndRecord` only
    /// during AVAudioRecorder use, then come back here.
    /// Sets category and options without activating the session. Safe to call
    /// at app launch — does not interrupt background audio.
    public static func prepareCategory() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                options: [.mixWithOthers])
        } catch {
            log("prepareCategory failed: \(error.localizedDescription)")
        }
        #endif
    }

    #if os(iOS)
    /// Option set for ducked playback. Exposed for testing — activation itself
    /// isn't unit-testable, but the chosen options are the meaningful contract.
    public static let duckedPlaybackOptions: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .duckOthers]
    #endif

    /// Activate a ducking playback session: other apps' audio (Music/Spotify)
    /// is *lowered* while this session is active instead of paused or plainly
    /// mixed. Restore other apps to full volume with `deactivate()`, which
    /// signals `.notifyOthersOnDeactivation`.
    public static func configureForDuckedPlayback() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: duckedPlaybackOptions)
            try s.setActive(true)
        } catch {
            log("configureForDuckedPlayback failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Activate the playback-only session (`.playback`) with mixing.
    /// Use whenever the app is going from idle/recording back into playback.
    public static func configureForPlayback() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            log("configureForPlayback failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Re-`setActive(true)` without changing category/options. Used by the
    /// interruption-ended path so we don't have to rebuild the full
    /// configuration just to wake the session back up.
    public static func reactivate() {
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { log("reactivate failed: \(error.localizedDescription)") }
        #endif
    }

    /// Fully release the session so background apps (Music/Spotify) get the
    /// un-duck signal immediately. Called on user-initiated stop().
    /// Switches to `.ambient` before deactivating so iOS fully releases
    /// session attributes before the deactivation signal reaches other apps.
    public static func deactivate() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.ambient, options: [.mixWithOthers])
        } catch {
            log("deactivate: ambient setCategory failed: \(error.localizedDescription)")
        }
        do {
            try s.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log("deactivate failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Widen the IO buffer to cut render-callback frequency during a known
    /// silent window (e.g. a gap between tracks) — trades a bit of latency
    /// for far fewer real-time-thread wakeups while nothing is rendering.
    /// Returns the previous `ioBufferDuration` so the caller can restore it
    /// before real audio needs to start.
    public static func widenIOBufferForGap(seconds: TimeInterval = 0.5) -> TimeInterval {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let previous = s.ioBufferDuration
        do { try s.setPreferredIOBufferDuration(seconds) }
        catch { log("widenIOBufferForGap failed: \(error.localizedDescription)") }
        return previous
        #else
        return 0
        #endif
    }

    /// Restore an `ioBufferDuration` captured from `widenIOBufferForGap`.
    /// No-op if `seconds` is 0 (i.e. the buffer was never widened).
    public static func restoreIOBufferDuration(_ seconds: TimeInterval) {
        #if os(iOS)
        guard seconds > 0 else { return }
        do { try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(seconds) }
        catch { log("restoreIOBufferDuration failed: \(error.localizedDescription)") }
        #endif
    }

    /// Call when AVAudioRecorder stops. Briefly deactivates the session with
    /// `.notifyOthersOnDeactivation` so background music apps receive the
    /// interruption-ended signal and resume, then re-arms the mix-friendly
    /// playback session.
    public static func endRecordingSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        configureForPlayback()
        #endif
    }

    /// Switch the session to `.playAndRecord` for AVAudioRecorder. With
    /// `useBluetoothMic == true` adds `.allowBluetooth` (HFP). Caller must
    /// invoke `endRecordingSession()` afterwards to restore the mix state.
    public static func configureForRecording(useBluetoothMic: Bool) {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if useBluetoothMic { opts.insert(.allowBluetooth) }
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: opts)
            try s.setActive(true)
        } catch {
            log("configureForRecording failed: \(error.localizedDescription)")
        }
        #endif
    }
}
