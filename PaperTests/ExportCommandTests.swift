import Foundation
import PDFKit
import Testing
@testable import Paper

/// `paper export`: the arguments the launcher hands the app, and one run
/// of the app's own executable from start to exit.
struct ExportCommandTests {
    private let directory = URL(fileURLWithPath: "/work/dir", isDirectory: true)

    private func parse(_ arguments: String...) throws -> ExportCommand.Request {
        try ExportCommand.parse(arguments, relativeTo: directory)
    }

    @Test
    func thePDFGoesBesideTheSourceUnderItsName() throws {
        let request = try parse("notes/memo.md")
        #expect(request.source.path == "/work/dir/notes/memo.md")
        #expect(request.destination.path == "/work/dir/notes/memo.pdf")
        #expect(request.paper == nil)
        #expect(try parse("/abs/plain").destination.path == "/abs/plain.pdf")
    }

    @Test
    func outputAndPaperAreTakenInAnyOrder() throws {
        let request = try parse("--paper", "A4", "-o", "out/x.pdf", "memo.md", "--pdf")
        #expect(request.source.path == "/work/dir/memo.md")
        #expect(request.destination.path == "/work/dir/out/x.pdf")
        #expect(request.paper == .a4)
        #expect(try parse("memo.md", "--output", "/tmp/y.pdf", "--paper", "letter")
            == ExportCommand.Request(
                source: URL(fileURLWithPath: "/work/dir/memo.md"),
                destination: URL(fileURLWithPath: "/tmp/y.pdf"), paper: .letter))
    }

    @Test
    func doubleDashEndsOptions() throws {
        #expect(try parse("--", "--paper").source.path == "/work/dir/--paper")
        #expect(try parse("--", "-o").destination.path == "/work/dir/-o.pdf")
    }

    @Test
    func mistakesAreUsageErrors() {
        #expect(throws: ExportCommand.UsageError.self) { try parse() }
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.md", "b.md") }
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.md", "-o") }
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.md", "--paper", "legal") }
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.md", "--html") }
        // The PDF may not land on its own source.
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.pdf") }
        #expect(throws: ExportCommand.UsageError.self) { try parse("a.md", "-o", "a.md") }
    }

    /// The app's executable, run the way the launcher runs it, with a
    /// config directory of its own. The runs meant to fail get a print
    /// server address nothing answers at, so a regression there cannot
    /// reach a printer; the run meant to succeed keeps the real one,
    /// which is where the paper sizes come from.
    private func run(
        _ arguments: [String], in folder: URL, printServer: Bool = false
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try #require(Bundle.main.executableURL)
        process.arguments = [ExportCommand.flag] + arguments
        process.currentDirectoryURL = folder
        var environment = [
            "HOME": NSHomeDirectory(),
            "XDG_CONFIG_HOME": folder.appendingPathComponent("config").path,
            "LLVM_PROFILE_FILE": "/dev/null",
        ]
        if !printServer { environment["CUPS_SERVER"] = "127.0.0.1:9" }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    @Test
    func theExecutableExportsReportsAndExits() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        let folder = URL(fileURLWithPath: realpath(temporary, nil).map { String(cString: $0) } ?? temporary)
            .appendingPathComponent("paper-export-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Memo\n\nSome **words**.\n".write(to: folder.appendingPathComponent("memo.md"), atomically: true, encoding: .utf8)

        let made = try run(["memo.md", "--paper", "a4"], in: folder, printServer: true)
        let output = folder.appendingPathComponent("memo.pdf")
        #expect(made.status == 0, Comment(rawValue: made.stderr))
        #expect(made.stdout.hasSuffix("\n"))
        let reported = URL(fileURLWithPath: made.stdout.trimmingCharacters(in: .newlines))
        #expect(reported.resolvingSymlinksInPath() == output.resolvingSymlinksInPath())
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("Memo") == true)
        #expect(document.string?.contains("**") == false)
        let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - PDFExporter.Paper.a4.size.width) < 0.5)
        // Reading the config is all an export does with it: no template.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("config").path))

        let missing = try run(["absent.md"], in: folder)
        #expect(missing.status == 1)
        #expect(missing.stderr.hasPrefix("paper: absent.md was not exported"))
        #expect(missing.stdout.isEmpty)

        // A folder that is not there fails before the print operation runs.
        let nowhere = try run(["memo.md", "-o", "absent/memo.pdf"], in: folder)
        #expect(nowhere.status == 1)
        #expect(nowhere.stderr.contains("could not be written"))

        let usage = try run([], in: folder)
        #expect(usage.status == 2)
        #expect(usage.stderr.contains("usage: paper export"))
    }
}
