//
//  AudioClip.swift
//  AudioClipKit
//
//  Host contract for a single recorded audio clip. A host app conforms its
//  own model (e.g. a SwiftData / Core Data record that stores the audio as a
//  blob) to this protocol; the kit stays free of any persistence opinion.
//

import Foundation

public protocol AudioClip {
    /// Stable identity used to key the waveform cache and detect "same clip"
    /// on preview resume. For a persisted model, its `persistentModelID` /
    /// `objectID` is a natural fit.
    var clipID: AnyHashable { get }

    /// A file URL AVFoundation can read. Blob-backed hosts materialize their
    /// bytes to a temp file and return that URL (size-cached so repeat calls
    /// are cheap). Returns `nil` when there is no audio yet.
    func audioURL() -> URL?
}

/// A ready-to-play, `Sendable` snapshot of a clip. Hosts whose model is
/// actor-isolated (e.g. SwiftData `@Model` on the main actor) build one of
/// these on their actor — resolving the audio URL there — and hand the plain
/// value to the non-isolated players, keeping isolation clean.
public struct AudioClipRef: AudioClip, @unchecked Sendable {
    public let clipID: AnyHashable
    private let url: URL?

    public init(clipID: AnyHashable, url: URL?) {
        self.clipID = clipID
        self.url = url
    }

    public func audioURL() -> URL? { url }
}
