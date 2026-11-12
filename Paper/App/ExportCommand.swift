import AppKit

/// `paper export <file>`: the PDF that File ▸ Export as PDF… makes, from
/// the terminal. The launcher runs the app's executable with `--export`
/// and the rest of its arguments; the app answers here and exits before
/// any window opens, so it works beside a running copy and when none is
/// open. The file on disk is what exports; unsaved edits in a window are
/// not seen.
enum ExportCommand {
    static let flag = "--export"

    struct Request: Equatable {
        var source: URL
        var destination: URL
        /// Nil is the system's paper, as in the save panel.
        var paper: PDFExporter.Paper?
    }

    /// A mistake in the arguments: reported with the usage line, exit 2.
    struct UsageError: Error, Equatable {
        let message: String
    }

    static let usage = "usage: paper export <file> [-o <out.pdf>] [--paper letter|a4]"

    /// Whether the process was started with the flag, from the launcher.
    static var requestedOnCommandLine: Bool {
        CommandLine.arguments.dropFirst().first == flag
    }

    /// The request in `arguments`, the ones after the flag. Paths resolve
    /// against `directory`. The PDF goes beside the source under its name
    /// unless `-o` says otherwise. `--pdf` names the only format there is.
    static func parse(_ arguments: [String], relativeTo directory: URL) throws -> Request {
        var source: String?
        var output: String?
        var paper: PDFExporter.Paper?
        var optionsEnded = false
        var index = 0

        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw UsageError(message: "\(option) needs a value")
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case _ where optionsEnded || !argument.hasPrefix("-") || argument == "-":
                guard source == nil else {
                    throw UsageError(message: "one file at a time; got \(source!) and \(argument)")
                }
                source = argument
            case "--":
                optionsEnded = true
            case "--pdf":
                break
            case "-o", "--output":
                output = try value(for: argument)
            case "--paper":
                let name = try value(for: argument)
                guard let match = PDFExporter.Paper.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                    throw UsageError(message: "--paper takes letter or a4, not \(name)")
                }
                paper = match
            default:
                throw UsageError(message: "unknown option \(argument)")
            }
            index += 1
        }

        guard let source, !source.isEmpty else {
            throw UsageError(message: "no file to export")
        }
        if let output, output.isEmpty {
            throw UsageError(message: "-o needs a value")
        }
        let sourceURL = URL(fileURLWithPath: source, relativeTo: directory).standardizedFileURL
        let destination = output.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL }
            ?? sourceURL.deletingPathExtension().appendingPathExtension("pdf")
        guard destination != sourceURL else {
            throw UsageError(message: "the PDF would replace \(sourceURL.path); name another file with -o")
        }
        return Request(source: sourceURL, destination: destination, paper: paper)
    }

    /// Reads the source and writes its PDF. The config file is read once,
    /// for the page's type, margins, and theme; it is neither created nor
    /// watched, which is the first launch's work.
    @MainActor
    static func export(_ request: Request) throws {
        let data = try Data(contentsOf: request.source)
        let text = try MarkdownDocument(data: data).text
        ConfigurationStore.shared.reload()
        ConfigurationStore.shared.loadThemes()
        try PDFExporter.export(
            text: text, documentURL: request.source, to: request.destination,
            paper: request.paper ?? .default
        )
    }

    /// Exports, reports on the standard streams, and exits: 0 with the
    /// PDF's path, 1 when the export failed, 2 when the arguments were
    /// wrong. Called from the app's initialiser, before the application
    /// runs. The application object exists for the print operation and
    /// stays out of the Dock and out of the way of the frontmost app.
    @MainActor
    static func runFromCommandLine() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst().drop(while: { $0 != flag }).dropFirst())
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let request: Request
        do {
            request = try parse(arguments, relativeTo: directory)
        } catch {
            let message = (error as? UsageError)?.message ?? error.localizedDescription
            fail("paper: \(message)\n\(usage)", status: 2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try export(request)
        } catch {
            fail("paper: \(request.source.lastPathComponent) was not exported: \(error.localizedDescription)", status: 1)
        }
        print(request.destination.path)
        exit(0)
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
