//
//  AudioClipRecorder.swift
//  AudioClipKit
//
//  Generalized from MindHeist's `AudioRecorderVm`. The Idea/Core-Data coupling
//  is gone: instead of writing a blob into a model and saving a MOC, `stop`
//  hands the finalized bytes + duration back through a completion closure so
//  the host decides storage. The trim phase is dropped (deferred).
//

import SwiftUI
import AVFoundation

@MainActor
public final class AudioClipRecorder: ObservableObject {

    public enum Phase {
        case ready
        case recording
    }

    @Published public private(set) var phase: Phase = .ready
    @Published public var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let useBluetoothMic: Bool

    public var isRecording: Bool {
        if case .recording = phase { return true } else { return false }
    }

    public init(useBluetoothMic: Bool = false) {
        self.useBluetoothMic = useBluetoothMic
    }

    /// Prompt for microphone access up front. Sets `errorMessage` on denial.
    public func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted { self.errorMessage = "Microphone access denied" }
            }
        }
    }

    public func start() {
        errorMessage = nil
        AudioSessionConfigurator.configureForRecording(useBluetoothMic: useBluetoothMic)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_\(UUID().uuidString).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.prepareToRecord()
            r.record()
            recorder = r
            phase = .recording
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    /// Stop, normalize, and hand back the finalized clip. `completion` runs on
    /// the main actor with the AAC bytes and the clip duration in seconds. Not
    /// called if the recording was empty (an error is surfaced instead).
    public func stop(completion: @escaping (_ data: Data, _ duration: TimeInterval) -> Void) {
        recorder?.stop()
        recorder = nil
        AudioSessionConfigurator.endRecordingSession()

        guard let url = recordingURL else {
            phase = .ready
            return
        }
        recordingURL = nil
        defer { phase = .ready; try? FileManager.default.removeItem(at: url) }

        // Normalize loudness; tolerated if the file isn't decodable.
        do { try AudioNormalizer.normalizeRMS(url: url) }
        catch { print("[AudioClipRecorder] normalization failed: \(error.localizedDescription)") }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            errorMessage = "Recording was empty — check microphone access"
            return
        }
        var duration: TimeInterval = 0
        if let file = try? AVAudioFile(forReading: url) {
            duration = Double(file.length) / file.processingFormat.sampleRate
        }
        completion(data, duration)
    }

    /// Abort the in-progress recording without handing anything back.
    public func cancel() {
        recorder?.stop()
        recorder = nil
        AudioSessionConfigurator.endRecordingSession()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        phase = .ready
    }
}
