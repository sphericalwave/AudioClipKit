import SwiftUI

/// Persistent playback bar meant to sit at the bottom of a
/// ZStack(alignment: .bottom) overlaying a TabView or a single screen.
/// Promoted out of beStillAndKnow's RootTabView.swift — visuals/behavior
/// unchanged, values/actions now supplied by the caller so hosts with
/// unrelated playback engines (SequentialClipPlayer vs. a custom engine)
/// can share one view.
public struct MiniPlayerBar: View {
    private let title: String
    private let subtitle: String?
    private let progress: Double
    private let isPlaying: Bool
    /// A future date to count down to (e.g. when a gap ends, or when the
    /// current track will finish) — nil hides the countdown entirely.
    private let countdownTarget: Date?
    private let onTogglePlayPause: () -> Void
    private let onTap: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        progress: Double,
        isPlaying: Bool,
        countdownTarget: Date? = nil,
        onTogglePlayPause: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.isPlaying = isPlaying
        self.countdownTarget = countdownTarget
        self.onTogglePlayPause = onTogglePlayPause
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let countdownTarget {
                    MiniPlayerCountdown(target: countdownTarget)
                }

                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Isolated countdown display — owns the TimelineView so 1-second ticks
/// don't invalidate the whole bar (title/progress keep updating independently).
private struct MiniPlayerCountdown: View {
    let target: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let seconds = max(0, Int(target.timeIntervalSince(ctx.date).rounded(.up)))
            Text("\(seconds)s")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
