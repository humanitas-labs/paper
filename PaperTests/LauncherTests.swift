import Foundation
import Testing

/// The `paper` shell launcher, run from a symlink into a fake bundle with a
/// stub `open` on the PATH that records its arguments.
struct LauncherTests {
    private struct Harness {
        let root: URL
        let bin: URL
        let cwd: URL
        let recorded: URL

        init() throws {
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Paper/Resources/paper")
            // Foundation drops /private from resolved paths; the shell
            // does not, so resolve the way the script's readlink -f does.
            let temporary = FileManager.default.temporaryDirectory.path
            let real = realpath(temporary, nil).map { String(cString: $0) } ?? temporary
            root = URL(fileURLWithPath: real)
                .appendingPathComponent("launcher-\(UUID().uuidString)")
            let resources = root.appendingPathComponent("Fake.app/Contents/Resources")
            bin = root.appendingPathComponent("bin")
            cwd = root.appendingPathComponent("wd")
            recorded = root.appendingPathComponent("open.args")
            for dir in [resources, bin, cwd] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent("paper"))
            let plist: [String: String] = ["CFBundleShortVersionString": "9.9"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Fake.app/Contents/Info.plist"))
            let stub = bin.appendingPathComponent("open")
            try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$PAPEL_TEST_OUT\"\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent("paper").path,
                withDestinationPath: "../Fake.app/Contents/Resources/paper")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        struct Result {
            var status: Int32
            var stdout: String
            var stderr: String
            var opened: [String]
        }

        func run(_ arguments: [String]) throws -> Result {
            try? FileManager.default.removeItem(at: recorded)
            let process = Process()
            process.executableURL = bin.appendingPathComponent("paper")
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.environment = [
                "PATH": "\(bin.path):/usr/bin:/bin",
                "PAPEL_TEST_OUT": recorded.path,
            ]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            let opened = (try? String(contentsOf: recorded, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                opened: opened)
        }

        var app: String { root.appendingPathComponent("Fake.app").path }
    }

    @Test
    func noArgumentsOpensTheAppFoundThroughTheSymlink() throws {
        let h = try Harness()
        defer { h.remove() }
        let result = try h.run([])
        #expect(result.status == 0)
        #expect(result.opened == ["-a", h.app])
    }

    @Test
    func filesAreCreatedAndPassedAsAbsolutePaths() throws {
        let h = try Harness()
        defer { h.remove() }
        try FileManager.default.createDirectory(at: h.cwd.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        let result = try h.run(["a b.md", "-dash.md", "sub dir/c.md"])
        #expect(result.status == 0)
        let expected = ["a b.md", "-dash.md", "sub dir/c.md"].map { h.cwd.appendingPathComponent($0).path }
        #expect(result.opened == ["-a", h.app] + expected)
        for path in expected {
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test
    func existingFilesAreLeftAlone() throws {
        let h = try Harness()
        defer { h.remove() }
        let file = h.cwd.appendingPathComponent("kept.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        let result = try h.run(["kept.md"])
        #expect(result.status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "content")
    }

    @Test
    func helpAndVersionDoNotCreateFiles() throws {
        let h = try Harness()
        defer { h.remove() }
        let help = try h.run(["--help"])
        #expect(help.status == 0)
        #expect(help.stdout.hasPrefix("usage: paper"))
        let version = try h.run(["--version"])
        #expect(version.status == 0)
        #expect(version.stdout == "9.9\n")
        #expect(help.opened.isEmpty && version.opened.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.cwd.path).isEmpty)
    }

    @Test
    func setDefaultRunsTheAppExecutable() throws {
        let h = try Harness()
        defer { h.remove() }
        let macOS = h.root.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let stub = macOS.appendingPathComponent("Paper")
        try "#!/bin/sh\nprintf 'stub %s\\n' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let result = try h.run(["--set-default"])
        #expect(result.status == 0)
        #expect(result.stdout == "stub --set-default\n")
        #expect(result.opened.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.cwd.path).isEmpty)
    }

    @Test
    func exportRunsTheAppExecutableWithItsArguments() throws {
        let h = try Harness()
        defer { h.remove() }
        let missing = try h.run(["export", "a.md"])
        #expect(missing.status == 1)
        #expect(missing.stderr.contains("no app at"))

        let macOS = h.root.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let stub = macOS.appendingPathComponent("Paper")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let result = try h.run(["export", "a b.md", "-o", "out dir/x.pdf", "--paper", "a4"])
        #expect(result.status == 0)
        #expect(result.stdout == [h.cwd.path, "--export", "a b.md", "-o", "out dir/x.pdf", "--paper", "a4"].joined(separator: "\n") + "\n")
        #expect(result.opened.isEmpty)
        // Nothing is created: the source must exist, and the app says so.
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.cwd.path).isEmpty)

        // A file of that name still opens, by path.
        let opened = try h.run(["./export"])
        #expect(opened.opened == ["-a", h.app, h.cwd.path + "/./export"])
    }

    @Test
    func setDefaultWithoutTheExecutableFails() throws {
        let h = try Harness()
        defer { h.remove() }
        let result = try h.run(["--set-default"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("no app at"))
        #expect(result.opened.isEmpty)
    }

    @Test
    func doubleDashEndsOptions() throws {
        let h = try Harness()
        defer { h.remove() }
        let result = try h.run(["--", "--help"])
        #expect(result.status == 0)
        #expect(result.opened == ["-a", h.app, h.cwd.appendingPathComponent("--help").path])
    }

    @Test
    func aMissingDirectoryFailsWithoutOpening() throws {
        let h = try Harness()
        defer { h.remove() }
        let result = try h.run(["nope/x.md"])
        #expect(result.status == 1)
        #expect(result.opened.isEmpty)
    }

    @Test
    func aMissingAppFails() throws {
        let h = try Harness()
        defer { h.remove() }
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let version = try h.run(["--version"])
        #expect(version.status == 1)
        #expect(version.stderr.contains("no app at"))
        let open = try h.run(["x.md"])
        #expect(open.status == 1)
        #expect(open.opened.isEmpty)
    }
}
