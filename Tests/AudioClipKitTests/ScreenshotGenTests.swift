import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import AudioClipKit

/// Renders one screenshot per public view into `Docs/img/` and keeps the
/// README's `<!-- SCREENSHOTS -->` table in sync. Rendering only runs in CI
/// (guarded by `GEN_SCREENSHOTS=1`) so a normal `swift test` never dirties the
/// tree. `testRegistryCoversEveryPublicView` runs always and is the drift gate.
@MainActor
final class ScreenshotGenTests: XCTestCase {

    private var registry: [(name: String, size: CGSize, view: AnyView)] {
        [
            ("WaveformBars", CGSize(width: 360, height: 96),
             AnyView(WaveformBars(peaks: AudioClipKitSamples.peaks, color: .accentColor)
                .frame(height: 60).padding())),
            ("StaticWaveformView", CGSize(width: 360, height: 96),
             AnyView(StaticWaveformView(clip: AudioClipKitSamples.clip, color: .accentColor, progress: 0.35)
                .frame(height: 60).padding())),
            ("MiniPlayerBar", CGSize(width: 380, height: 108),
             AnyView(MiniPlayerBar(title: "Morning Meditation", subtitle: "Track 2 of 5",
                                   progress: 0.42, isPlaying: true,
                                   countdownTarget: Date().addingTimeInterval(45),
                                   onTogglePlayPause: {}, onTap: {}).padding(.vertical))),
            ("AudioRecordingSheet", CGSize(width: 390, height: 640),
             AnyView(AudioRecordingSheet(
                title: "Record Script",
                bodyText: "Breathe in slowly for four counts, hold for four, and release for four.",
                recorder: AudioClipRecorder()) { _, _ in })),
        ]
    }

    // MARK: Drift gate (always runs)

    func testRegistryCoversEveryPublicView() throws {
        let found = try Self.publicViewNames(in: Self.sourcesDir)
        let missing = found.subtracting(Set(registry.map(\.name))).sorted()
        XCTAssertTrue(missing.isEmpty,
            "Public views without a screenshot registry entry: \(missing). " +
            "Add them to ScreenshotGenTests.registry and re-run with GEN_SCREENSHOTS=1.")
    }

    // MARK: Generation (CI only)

    func testGenerateScreenshotsAndReadme() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEN_SCREENSHOTS"] == "1",
                          "Set GEN_SCREENSHOTS=1 to (re)generate screenshots + README.")
        AudioClipKitSamples.seedWaveformCache()

        let imgDir = Self.packageRoot.appendingPathComponent("Docs/img")
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)

        for entry in registry {
            let url = imgDir.appendingPathComponent("\(Self.kebab(entry.name)).png")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try render(entry.view, size: entry.size, to: url)
        }
        try updateReadmeTable()
    }

    // MARK: Rendering

    private func render(_ view: AnyView, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw Failure("No image for \(url.lastPathComponent)") }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("No PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("Write failed at \(url.path)") }
    }

    // MARK: README table

    private func updateReadmeTable() throws {
        let readme = Self.packageRoot.appendingPathComponent("README.md")
        var text = try String(contentsOf: readme, encoding: .utf8)
        let start = "<!-- SCREENSHOTS:START -->", end = "<!-- SCREENSHOTS:END -->"
        guard let s = text.range(of: start), let e = text.range(of: end), s.upperBound <= e.lowerBound else {
            throw Failure("README is missing the SCREENSHOTS markers.")
        }
        var rows = "\n| Component | Preview |\n| --- | --- |\n"
        for name in registry.map(\.name).sorted() {
            rows += "| `\(name)` | ![\(name)](Docs/img/\(Self.kebab(name)).png) |\n"
        }
        text.replaceSubrange(s.upperBound..<e.lowerBound, with: rows)
        try text.write(to: readme, atomically: true, encoding: .utf8)
    }

    // MARK: Source scan

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesDir = packageRoot.appendingPathComponent("Sources")

    static func publicViewNames(in dir: URL) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"^\s*public\s+struct\s+([A-Za-z_]\w*)\b[^:{]*:\s*[^{]*\bView\b"#)
        var names = Set<String>()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r = Range(m.range(at: 1), in: s) {
                    names.insert(String(s[r]))
                }
            }
        }
        return names
    }

    static func kebab(_ name: String) -> String {
        var out = ""
        for (i, ch) in name.enumerated() {
            if ch.isUppercase && i != 0 { out += "-" }
            out += ch.lowercased()
        }
        return out
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
