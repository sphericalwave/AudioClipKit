//
//  AudioSessionHealthMonitor.swift
//  AudioClipKit
//
//  Schedules AudioSessionConfigurator.verifyAndCorrect() while the app is in
//  the foreground: once immediately on becoming active, then on a repeating
//  interval, and never while backgrounded (nothing to correct if the app
//  isn't producing audio anyway, and a foreground-only timer avoids waking
//  the app on the OS's dime).
//
//  Purely a scheduler — the actual comparison, correction, and logging live
//  in AudioSessionConfigurator so both the policy and its diagnostic trail
//  stay in one place.
//

import Foundation
#if os(iOS)
import UIKit
#endif

public final class AudioSessionHealthMonitor {

    public static let shared = AudioSessionHealthMonitor()

    /// How often to re-check while foregrounded. Changing it takes effect on
    /// the next foreground transition.
    public var interval: TimeInterval = 30

    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    /// Start observing foreground/background transitions. Idempotent — safe
    /// to call from the app's `init()`.
    public func start() {
        #if os(iOS)
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.beginForegroundChecks() })
        tokens.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.endForegroundChecks() })
        if UIApplication.shared.applicationState == .active {
            beginForegroundChecks()
        }
        #endif
    }

    public func stop() {
        #if os(iOS)
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        endForegroundChecks()
        started = false
        #endif
    }

    private func beginForegroundChecks() {
        #if os(iOS)
        AudioSessionConfigurator.verifyAndCorrect()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            AudioSessionConfigurator.verifyAndCorrect()
        }
        #endif
    }

    private func endForegroundChecks() {
        #if os(iOS)
        timer?.invalidate()
        timer = nil
        #endif
    }
}
