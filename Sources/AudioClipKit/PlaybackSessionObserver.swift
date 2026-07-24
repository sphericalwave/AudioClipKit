//
//  PlaybackSessionObserver.swift
//  AudioClipKit
//
//  Owns the session-event observers a continuous playback engine needs to
//  stay correct: route changes (headphone yank), interruptions (calls/Siri),
//  media-services-reset (audio daemon restart), and app background/
//  foreground (to pause/resume a progress timer). No-op on macOS.
//

import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

final class PlaybackSessionObserver: NSObject {
    var onRouteChangeShouldPause: (() -> Void)?
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEndedShouldResume: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onDidEnterBackground: (() -> Void)?
    var onWillEnterForeground: (() -> Void)?

    /// Consulted by the route-change/interruption handlers to decide what to
    /// do and what to log. The host wires these to its own player state.
    var isPlaying: () -> Bool = { false }
    var isPaused: () -> Bool = { false }
    var isNodePlaying: () -> Bool = { false }
    var log: (String) -> Void = { _ in }

    override init() {
        super.init()
        register()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func register() {
        #if os(iOS)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    #if os(iOS)
    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        log("routeChange reason=\(reason.rawValue) isPlaying=\(isPlaying()) nodeIsPlaying=\(isNodePlaying())")
        if reason == .oldDeviceUnavailable, isPlaying(), isNodePlaying() {
            onRouteChangeShouldPause?()
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            log("interruption began isPlaying=\(isPlaying())")
            if isPlaying() { onInterruptionBegan?() }
        case .ended:
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            log("interruption ended shouldResume=\(opts.contains(.shouldResume)) isPaused=\(isPaused())")
            if opts.contains(.shouldResume), isPaused() {
                onInterruptionEndedShouldResume?()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        onMediaServicesReset?()
    }

    @objc private func handleDidEnterBackground() {
        onDidEnterBackground?()
    }

    @objc private func handleWillEnterForeground() {
        onWillEnterForeground?()
    }
    #endif
}
