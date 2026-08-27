//
//  WaveformPinPicker.swift
//  AudioClipKit
//
//  Lets the user scrub across an existing clip's waveform and drop a pin to
//  pick an insertion time, ahead of recording new audio to splice in there.
//  Reuses WaveformBars for rendering; adds a drag gesture + pin overlay.
//  Host-agnostic like AudioRecordingSheet: takes a clip + duration, hands
//  back a chosen time in seconds via `onConfirm`.
//

import SwiftUI

public struct WaveformPinPicker: View {
    private let clip: any AudioClip
    private let duration: TimeInterval
    private let onConfirm: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = ClipPreviewPlayer()
    @State private var peaks: [Float] = []
    @State private var pinProgress: Double = 0.5

    public init(clip: any AudioClip,
                duration: TimeInterval,
                onConfirm: @escaping (TimeInterval) -> Void) {
        self.clip = clip
        self.duration = duration
        self.onConfirm = onConfirm
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Drag to place the insertion point, then continue to record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Button {
                        player.toggle(clip)
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                    }
                    .buttonStyle(.plain)

                    Text(timeString(pinProgress * duration))
                        .font(.title2.monospacedDigit())
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        WaveformBars(peaks: peaks, color: .secondary)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .offset(x: geo.size.width * pinProgress - 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if player.isPlaying { player.toggle(clip) }
                                let x = min(max(value.location.x, 0), geo.size.width)
                                pinProgress = geo.size.width > 0 ? Double(x / geo.size.width) : 0
                                player.seek(to: pinProgress)
                            }
                    )
                }
                .frame(height: 60)

                Spacer()

                Button {
                    player.stop()
                    onConfirm(pinProgress * duration)
                    dismiss()
                } label: {
                    Label("Continue to Record", systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Insert Point")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { player.stop(); dismiss() }
                }
            }
            .onChange(of: player.progress) { _, newValue in
                // Pin tracks live playback so pausing at the right moment
                // is how the user locates the insertion point; a manual
                // drag stops playback first (above), so this never fights
                // an in-progress drag.
                guard player.isPlaying else { return }
                pinProgress = newValue
            }
            .onDisappear { player.stop() }
            .task(id: clip.clipID) {
                player.load(clip)
                player.seek(to: pinProgress)

                let id = clip.clipID
                if let cached = WaveformCache.shared.get(id) {
                    peaks = cached
                    return
                }
                guard let url = clip.audioURL() else { return }
                let computed = await Task.detached(priority: .utility) {
                    Waveform.peaks(from: url, count: 80)
                }.value
                guard let computed else { return }
                WaveformCache.shared.set(id, peaks: computed)
                peaks = computed
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let m = Int(clamped) / 60
        let s = Int(clamped) % 60
        let ms = Int((clamped - Double(Int(clamped))) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }
}
