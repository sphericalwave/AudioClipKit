# AudioClipKit

Record, trim, normalize, and play back short audio clips in SwiftUI apps.

## Requirements

- iOS 17+ / macOS 14+
- Swift 5.9+

## Installation

```swift
.package(url: "https://github.com/sphericalwave/AudioClipKit.git", branch: "main")
```

## Overview

- `AudioClip` / `AudioClipRef` — protocol + concrete type identifying a stored clip
- `AudioClipRecorder` — `ObservableObject` driving a recording session
- `AudioRecordingSheet` — ready-made recording UI
- `AudioTrimmer` — trims a clip to a start/end range
- `AudioNormalizer` — peak-normalizes clip audio
- `GapSampler` — detects silence gaps for trimming/segmenting
- `Waveform` / `WaveformCache` / `WaveformBars` / `StaticWaveformView` — waveform generation and display
- `SequentialClipPlayer` — plays a queue of clips back to back
- `ClipPreviewPlayer` — single-clip preview playback
- `AudioSessionConfigurator` — configures `AVAudioSession` for recording/playback

## Dependencies

None.
