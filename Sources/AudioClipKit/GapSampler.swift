//
//  GapSampler.swift
//  AudioClipKit
//
//  Moved from MindHeist unchanged apart from `public`. Picks the pause length
//  between clips in a sequence.
//

import Foundation

public enum GapSampler {
    /// Picks the next gap duration from `[lo, hi]` split into 4 equal buckets,
    /// never returning the same bucket index twice in a row.
    /// Caller must ensure `hi > lo`; pass `lastBucket: -1` on first call.
    public static func next(lo: Double, hi: Double, lastBucket: inout Int) -> Double {
        guard hi > lo else { return lo }
        let bucketCount = 4
        let width = (hi - lo) / Double(bucketCount)
        var idx = Int.random(in: 0..<bucketCount)
        if idx == lastBucket {
            idx = (idx + 1 + Int.random(in: 0..<(bucketCount - 1))) % bucketCount
        }
        lastBucket = idx
        let bLo = lo + Double(idx) * width
        return Double.random(in: bLo..<(bLo + width))
    }
}
