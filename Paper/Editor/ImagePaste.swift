#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

/// An image pasted or dropped into a document lands on disk beside it and
/// is inserted as a block image with a relative path (#36). The document is
/// a portable file the writer owns, so the image lives in its folder (or a
/// subfolder named by `image.paste.directory`), never in a staging area
/// under `~` that a move or a share would leave behind.
enum ImagePaste {
    /// The image a pasteboard carries, in preference order: a file already
    /// on disk (a Finder copy or drop) is copied as it is, keeping its
    /// format; bitmap data (a screenshot, an image copied from a browser)
    /// is written as PNG.
    enum Source {
        case file(URL)
        case png(Data)

        var pathExtension: String {
            switch self {
            case .file(let url): url.pathExtension.lowercased()
            case .png: "png"
            }
        }
    }

    #if os(macOS)
    /// The image on `pasteboard`, or nil when it holds none. Text beside an
    /// image is ignored: an app that copies a picture with a caption meant
    /// the picture.
    static func source(on pasteboard: NSPasteboard) -> Source? {
        if let url = imageFileURL(on: pasteboard) { return .file(url) }
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return .png(png) }
        if let tiff = pasteboard.data(forType: .tiff), let png = pngData(from: tiff) { return .png(png) }
        return nil
    }

    /// The first file URL on the pasteboard that names an image on disk.
    static func imageFileURL(on pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.first { isImageFile($0) }
    }
    #endif

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && FileManager.default.fileExists(atPath: url.path)
    }

    /// Re-encodes bitmap data (TIFF from the pasteboard) as PNG.
    static func pngData(from data: Data) -> Data? {
        #if os(macOS)
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        UIImage(data: data)?.pngData()
        #endif
    }

    // MARK: - Destination

    /// A paste directory is a path relative to the document, inside its
    /// folder: no leading slash, no `..` segment, no `~`. Anything else is
    /// rejected so the config cannot send images away from the document.
    static func isAcceptableDirectory(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return false }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return !segments.isEmpty && !segments.contains { $0 == ".." }
    }

    /// The folder an image is written into: the document's own, or
    /// `directory` beneath it. Created on demand.
    static func folder(for documentURL: URL, directory: String) throws -> URL {
        var folder = documentURL.deletingLastPathComponent()
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        if isAcceptableDirectory(trimmed), !trimmed.isEmpty {
            for segment in trimmed.split(separator: "/", omittingEmptySubsequences: true) where segment != "." {
                folder.appendPathComponent(String(segment), isDirectory: true)
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// `notes-20260903-141205.png`: the document's name, a timestamp, and
    /// the format's extension. Whitespace in the name becomes `-` so the
    /// path fits inside `![]( )` without escaping. A name already taken
    /// gets a counter: `notes-20260903-141205-2.png`.
    static func fileName(
        for documentURL: URL,
        extension pathExtension: String,
        date: Date = Date(),
        taken: (String) -> Bool
    ) -> String {
        let base = documentURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = "\(base.isEmpty ? "image" : base)-\(stamp.string(from: date))"
        var candidate = "\(stem).\(pathExtension)"
        var counter = 2
        while taken(candidate) {
            candidate = "\(stem)-\(counter).\(pathExtension)"
            counter += 1
        }
        return candidate
    }

    /// Writes the image beside `documentURL` and returns the destination to
    /// put in the Markdown: the file name, under `directory` when set,
    /// percent-encoded where a segment needs it.
    static func write(
        _ source: Source,
        beside documentURL: URL,
        directory: String,
        date: Date = Date()
    ) throws -> String {
        let folder = try folder(for: documentURL, directory: directory)
        let name = fileName(for: documentURL, extension: source.pathExtension, date: date) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let target = folder.appendingPathComponent(name)
        switch source {
        case .file(let url):
            try FileManager.default.copyItem(at: url, to: target)
        case .png(let data):
            try data.write(to: target, options: .withoutOverwriting)
        }
        let base = documentURL.deletingLastPathComponent().standardizedFileURL
        let relative = target.standardizedFileURL.path.dropFirst(base.path.count + 1)
        return relative.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
        }.joined(separator: "/")
    }

    // MARK: - Insertion

    /// The text that puts `![](destination)` on a line of its own at
    /// `range`, and where the caret lands afterwards: on a fresh line under
    /// the image. A caret mid-paragraph splits the paragraph around the
    /// image with a blank line each side, so the image is a block and the
    /// prose keeps its shape.
    static func insertion(
        of destination: String,
        replacing range: NSRange,
        in text: NSString
    ) -> (replacement: String, selection: NSRange) {
        let image = "![](\(destination))"
        let before = text.substring(to: range.location)
        let after = text.substring(from: range.location + range.length)

        var prefix = ""
        if !before.isEmpty {
            if !before.hasSuffix("\n") { prefix = "\n\n" }
            else if !before.hasSuffix("\n\n") { prefix = "\n" }
        }
        // The image line always ends; prose following directly gets a
        // blank line between, so the image stands alone.
        let suffix = (!after.isEmpty && !after.hasPrefix("\n")) ? "\n\n" : "\n"
        let replacement = prefix + image + suffix
        let caret = range.location + (prefix + image + "\n").utf16.count
        return (replacement, NSRange(location: caret, length: 0))
    }
}
