//
//  AudioRecordingSheet.swift
//  AudioClipKit
//
//  Reusable recording sheet, generalized from MindHeist's AudioRecorderView:
//  shows the source text prominently while recording, with Record/Pause/
//  Stop/Cancel driven by an `AudioClipRecorder`'s phase. Pause is new — long
//  scripts can be interrupted mid-recording and resumed into the same file.
//  Kept host-agnostic (title/body strings + a completion closure) so any app
//  consuming AudioClipKit can present it without writing its own version.
//

import SwiftUI

public struct AudioRecordingSheet: View {
    private let title: String
    private let bodyText: String
    @ObservedObject private var recorder: AudioClipRecorder
    private let onFinished: (Data, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(title: String,
                bodyText: String,
                recorder: AudioClipRecorder,
                onFinished: @escaping (Data, TimeInterval) -> Void) {
        self.title = title
        self.bodyText = bodyText
        self.recorder = recorder
        self.onFinished = onFinished
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusLabel

                ScrollView {
                    Text(bodyText.isEmpty ? "No script text yet." : bodyText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))

                if let error = recorder.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                controls
            }
            .padding()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if recorder.phase != .recording {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            recorder.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { recorder.requestPermission() }
            // Force an explicit Stop/Cancel while audio is in flight so a
            // swipe-dismiss can't orphan the in-progress recording.
            .interactiveDismissDisabled(recorder.phase != .ready)
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.headline)
            .foregroundStyle(recorder.phase == .recording ? .red : .primary)
    }

    private var statusText: String {
        switch recorder.phase {
        case .ready: "Ready to Record"
        case .recording: "Recording…"
        case .paused: "Paused"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .ready:
            Button {
                recorder.start()
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.errorMessage != nil)

        case .recording:
            HStack(spacing: 16) {
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    finish()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .paused:
            HStack(spacing: 16) {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    finish()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private func finish() {
        recorder.stop { data, duration in
            onFinished(data, duration)
            dismiss()
        }
    }
}
