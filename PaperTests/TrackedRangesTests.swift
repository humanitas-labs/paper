import Foundation
import Testing
@testable import Paper

/// A tracked range keeps pointing at the same text through edits around
/// and inside it, and ends only when all of its text is replaced.
struct TrackedRangesTests {
    /// Applies an edit to the text and reports it the way the storage does.
    private func edit(_ text: inout NSMutableString, _ ranges: inout TrackedRanges, replace range: NSRange, with string: String) {
        text.replaceCharacters(in: range, with: string)
        let length = (string as NSString).length
        ranges.edited(NSRange(location: range.location, length: length), changeInLength: length - range.length)
    }

    private func tracked(_ source: String, _ word: String) -> (NSMutableString, TrackedRanges) {
        let text = NSMutableString(string: source)
        var ranges = TrackedRanges()
        ranges.track(text.range(of: word), as: "sel-1")
        return (text, ranges)
    }

    private func text(of id: String, in text: NSString, _ ranges: TrackedRanges) -> String? {
        guard case .live(let range) = ranges.state(of: id) else { return nil }
        return text.substring(with: range)
    }

    @Test
    func textTypedAboveMovesTheRange() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 0, length: 0), with: "A paragraph.\n\n")
        #expect(self.text(of: "sel-1", in: text, ranges) == "two")
    }

    @Test
    func textDeletedAboveMovesTheRange() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 0, length: 4), with: "")
        #expect(ranges.state(of: "sel-1") == .live(NSRange(location: 0, length: 3)))
        #expect(self.text(of: "sel-1", in: text, ranges) == "two")
    }

    @Test
    func textTypedAtTheFirstCharacterStaysOutside() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 4, length: 0), with: "X")
        #expect(self.text(of: "sel-1", in: text, ranges) == "two")
    }

    @Test
    func textTypedAfterLeavesTheRangeAlone() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 7, length: 0), with: "X")
        edit(&text, &ranges, replace: NSRange(location: text.length, length: 0), with: " four")
        #expect(ranges.state(of: "sel-1") == .live(NSRange(location: 4, length: 3)))
    }

    @Test
    func editsInsideGrowAndShrinkTheRange() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 5, length: 0), with: "XY")
        #expect(self.text(of: "sel-1", in: text, ranges) == "tXYwo")
        edit(&text, &ranges, replace: NSRange(location: 5, length: 3), with: "")
        #expect(self.text(of: "sel-1", in: text, ranges) == "to")
    }

    @Test
    func anEditOverTheHeadKeepsTheRest() {
        var (text, ranges) = tracked("one two three", "two")
        // "e t" -> "__": takes the range's first character.
        edit(&text, &ranges, replace: NSRange(location: 2, length: 3), with: "__")
        #expect(self.text(of: "sel-1", in: text, ranges) == "wo")
    }

    @Test
    func anEditOverTheTailKeepsTheRest() {
        var (text, ranges) = tracked("one two three", "two")
        // "o t" -> "__": takes the range's last character.
        edit(&text, &ranges, replace: NSRange(location: 6, length: 3), with: "__")
        #expect(self.text(of: "sel-1", in: text, ranges) == "tw")
    }

    @Test
    func replacingAllOfItEndsTheRange() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 3, length: 5), with: "-")
        #expect(ranges.state(of: "sel-1") == .gone)
        // Nothing brings it back, and its id is not taken again.
        edit(&text, &ranges, replace: NSRange(location: 0, length: 0), with: "two ")
        ranges.track(NSRange(location: 0, length: 3), as: "sel-1")
        #expect(ranges.state(of: "sel-1") == .gone)
    }

    @Test
    func replacingExactlyItsTextEndsTheRange() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 4, length: 3), with: "2")
        #expect(ranges.state(of: "sel-1") == .gone)
    }

    @Test
    func anIdNeverTrackedIsUnknown() {
        let ranges = TrackedRanges()
        #expect(ranges.state(of: "sel-9") == .unknown)
    }

    @Test
    func anEmptyRangeIsNotTracked() {
        var ranges = TrackedRanges()
        ranges.track(NSRange(location: 3, length: 0), as: "sel-1")
        #expect(ranges.state(of: "sel-1") == .unknown)
        #expect(ranges.count == 0)
    }

    @Test
    func theSameRangeGivesTheSameId() {
        var (text, ranges) = tracked("one two three", "two")
        #expect(ranges.id(for: NSRange(location: 4, length: 3)) == "sel-1")
        #expect(ranges.id(for: NSRange(location: 4, length: 2)) == nil)
        edit(&text, &ranges, replace: NSRange(location: 0, length: 0), with: "zero ")
        #expect(ranges.id(for: NSRange(location: 9, length: 3)) == "sel-1")
    }

    @Test
    func trackingPastCapacityEndsTheOldest() {
        var ranges = TrackedRanges(capacity: 2)
        ranges.track(NSRange(location: 0, length: 1), as: "a")
        ranges.track(NSRange(location: 1, length: 1), as: "b")
        ranges.track(NSRange(location: 2, length: 1), as: "c")
        #expect(ranges.state(of: "a") == .gone)
        #expect(ranges.state(of: "b") == .live(NSRange(location: 1, length: 1)))
        #expect(ranges.state(of: "c") == .live(NSRange(location: 2, length: 1)))
        #expect(ranges.count == 2)
    }

    @Test
    func endingAllEndsEveryRange() {
        var ranges = TrackedRanges()
        ranges.track(NSRange(location: 0, length: 1), as: "a")
        ranges.track(NSRange(location: 1, length: 1), as: "b")
        ranges.endAll()
        #expect(ranges.state(of: "a") == .gone)
        #expect(ranges.state(of: "b") == .gone)
    }

    @Test
    func severalRangesMoveIndependently() {
        let text = NSMutableString(string: "alpha beta gamma")
        var ranges = TrackedRanges()
        ranges.track(text.range(of: "alpha"), as: "a")
        ranges.track(text.range(of: "gamma"), as: "g")
        var mutable = text
        edit(&mutable, &ranges, replace: text.range(of: "beta"), with: "b")
        #expect(self.text(of: "a", in: mutable, ranges) == "alpha")
        #expect(self.text(of: "g", in: mutable, ranges) == "gamma")
    }

    @Test
    func charactersOutsideTheBasicPlaneCountAsTwoUnits() {
        var (text, ranges) = tracked("one two three", "two")
        edit(&text, &ranges, replace: NSRange(location: 0, length: 0), with: "𝒜😀")
        #expect(self.text(of: "sel-1", in: text, ranges) == "two")
    }
}
