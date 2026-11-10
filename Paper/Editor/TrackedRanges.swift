import Foundation

/// Character ranges that keep pointing at the same text while the text
/// around them is edited. A range is tracked under an id the caller
/// chooses; each edit to the text is reported once, and every tracked
/// range moves, grows, shrinks, or ends with it.
///
/// Ranges are in UTF-16 units, as `NSTextStorage` reports them. The
/// registry knows nothing about the text itself, only where it changed.
struct TrackedRanges: Sendable {
    enum State: Equatable, Sendable {
        /// The text is still there, at this range.
        case live(NSRange)
        /// The id was tracked and its text has since been deleted, or the
        /// id was dropped to make room.
        case gone
        /// The id was never tracked here.
        case unknown
    }

    /// The most ranges kept live; tracking one more ends the oldest.
    let capacity: Int
    private var live: [String: NSRange] = [:]
    /// Live ids, oldest first.
    private var order: [String] = []
    private var ended: Set<String> = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    var count: Int { live.count }

    /// Starts tracking `range` under `id`. An empty range is not tracked:
    /// it has no text to keep pointing at.
    mutating func track(_ range: NSRange, as id: String) {
        guard range.length > 0, live[id] == nil, !ended.contains(id) else { return }
        live[id] = range
        order.append(id)
        while order.count > capacity {
            end(order[0])
        }
    }

    /// The id of a live range that is exactly `range`, so asking twice
    /// about an unchanged selection gives the same id.
    func id(for range: NSRange) -> String? {
        order.last { live[$0] == range }
    }

    func state(of id: String) -> State {
        if let range = live[id] { return .live(range) }
        return ended.contains(id) ? .gone : .unknown
    }

    /// Applies one edit, described the way `NSTextStorage` describes it
    /// after the fact: `editedRange` is where the new text now sits, and
    /// `delta` is how much longer the whole text became. The text that
    /// was replaced therefore began at the same place and was
    /// `editedRange.length - delta` long.
    mutating func edited(_ editedRange: NSRange, changeInLength delta: Int) {
        let start = editedRange.location
        let inserted = editedRange.length
        let removed = inserted - delta
        guard removed >= 0, removed > 0 || inserted > 0 else { return }
        let end = start + removed

        for id in order {
            guard let range = live[id] else { continue }
            let lower = range.location
            let upper = range.location + range.length
            if end <= lower {
                // Wholly before, text typed at the range's first
                // character included: the range moves.
                live[id] = NSRange(location: lower + delta, length: range.length)
            } else if start >= upper {
                // Wholly after: nothing changes.
                continue
            } else if start <= lower, end >= upper {
                // The whole range was replaced.
                self.end(id)
            } else if start >= lower, end <= upper {
                // Inside: the range grows or shrinks around the edit.
                live[id] = NSRange(location: lower, length: range.length + delta)
            } else if start < lower {
                // The edit took the range's head; what follows the new
                // text is what remains.
                live[id] = NSRange(location: start + inserted, length: upper - end)
            } else {
                // The edit took the range's tail.
                live[id] = NSRange(location: lower, length: start - lower)
            }
        }
    }

    /// Ends every range, as when the whole text is replaced from outside.
    mutating func endAll() {
        for id in order { end(id) }
    }

    private mutating func end(_ id: String) {
        guard live.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        ended.insert(id)
    }
}
