import Foundation

/// A note made as `Untitled.md` takes its file name from its title once it
/// has one: `# Where to Begin?` becomes `where-to-begin.md`. Only untitled
/// notes are renamed, and only once the title line is finished (a line
/// break follows it), so a title half typed when the note is saved does
/// not name the file. A note already named by hand is never touched.
enum NoteNaming {
    private static let untitled = try! NSRegularExpression(pattern: #"^Untitled( \d+)?\.md$"#)

    static func isUntitled(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return untitled.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Lowercase words joined by hyphens, accents dropped, anything else
    /// left out: `Where to Begin?` → `where-to-begin`.
    static func kebab(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var words: [String] = []
        var word = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return String(words.joined(separator: "-").prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The note's first `# ` heading, when a line break follows it.
    static func finishedTitle(in text: String) -> String? {
        var inFrontMatter = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed == "---" { inFrontMatter = true; continue }
            if inFrontMatter { if trimmed == "---" { inFrontMatter = false }; continue }
            guard trimmed.hasPrefix("# ") else { continue }
            // The last line has no break after it yet.
            guard index < lines.count - 1 else { return nil }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// Renames each untitled note with a finished title, through file
    /// coordination, so a window showing the note follows it.
    static func nameFromTitles(_ urls: [URL]) {
        for url in urls where isUntitled(url) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            try? handle.close()
            guard let title = finishedTitle(in: head) else { continue }
            let slug = kebab(title)
            guard !slug.isEmpty else { continue }
            let folder = url.deletingLastPathComponent()
            var target = folder.appendingPathComponent(slug).appendingPathExtension("md")
            var index = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(slug)-\(index)").appendingPathExtension("md")
                index += 1
            }
            move(url, to: target)
        }
    }

    private static func move(_ source: URL, to target: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            if (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                coordinator.item(at: from, didMoveTo: to)
            }
        }
    }
}
