import Foundation

/// A caption entry carrying a monotonically increasing sequence number.
protocol CaptionSequenced {
    var seq: UInt64 { get }
}

/// Tracks which caption entries a consumer has already read.
struct CaptionCursor {
    private(set) var lastSeq: UInt64 = 0

    /// Returns the entries not yet seen, oldest → newest.
    /// - Parameter history: caption history ordered newest → oldest.
    mutating func take<T: CaptionSequenced>(newestFirst history: [T]) -> [T] {
        // History is descending by `seq`, so every unseen entry is at the front.
        let fresh = history.prefix { $0.seq > lastSeq }
        guard let newest = fresh.first else { return [] }
        lastSeq = newest.seq
        return Array(fresh.reversed())
    }
}
