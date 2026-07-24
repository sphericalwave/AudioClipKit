//
//  AudioEngineChain.swift
//  AudioClipKit
//
//  Shared AVAudioEngine playback pipeline: player node → gain EQ → main
//  mixer. `AVAudioUnitEQ.globalGain` (dB) is the gain stage — iOS caps
//  `mainMixerNode.volume` at 1.0, but globalGain supports −96...+24 dB.
//

import AVFoundation

final class AudioEngineChain {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    private let boostEQ = AVAudioUnitEQ(numberOfBands: 0)

    var gain: Float = 1.0 {
        didSet { boostEQ.globalGain = linearToDB(gain) }
    }

    init() {
        setup()
    }

    private func linearToDB(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10(linear) : -96
    }

    private func setup() {
        engine.attach(playerNode)
        engine.attach(boostEQ)
        engine.connect(playerNode, to: boostEQ, format: nil)
        engine.connect(boostEQ, to: engine.mainMixerNode, format: nil)
        boostEQ.globalGain = linearToDB(gain)
    }

    func start(onError: (Error) -> Void = { _ in }) {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() }
        catch { onError(error) }
    }

    /// Stops the node and engine, resets, and reattaches — so `start()` works
    /// again afterwards. Used for full teardown and for rebuilding after a
    /// media-services reset.
    func fullStop() {
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        engine.reset()
        setup()
    }

    /// Converts a delay in seconds to an `AVAudioTime` anchored to the
    /// current host clock — used to schedule node playback at a future time.
    func audioTime(secondsFromNow delay: Double) -> AVAudioTime {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanos = UInt64(delay * 1_000_000_000)
        let ticks = nanos * UInt64(info.denom) / UInt64(info.numer)
        return AVAudioTime(hostTime: mach_absolute_time() + ticks)
    }
}
