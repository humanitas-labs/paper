import Testing
import UIKit
@testable import Paper

private final class BundleMarker {}

/// Renders the fixture in a real window, screen by screen, in light and
/// dark, into `PAPER_PROBE_DIR`. Skipped when the variable is unset. Pass
/// it as `TEST_RUNNER_PAPER_PROBE_DIR=/abs/path xcodebuild test …`.
/// The PNGs are evidence to look at beside the Mac's probe, not a gate.
@MainActor
struct RenderProbeTests {
    static var probeDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PAPER_PROBE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var fixtureURL: URL {
        Bundle(for: BundleMarker.self).url(forResource: "fixture", withExtension: "md")!
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func rendersTheFixtureScreenByScreen(style: UIUserInterfaceStyle) async throws {
        guard let directory = Self.probeDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 402, height: 874)
        let (window, textView) = try Self.makeWindow(size: size, style: style)
        defer { window.isHidden = true }

        // Images decode off the main actor; give them a moment to land.
        try await Task.sleep(for: .milliseconds(800))
        textView.layoutIfNeeded()

        let name = style == .dark ? "dark" : "light"
        var offset: CGFloat = 0
        var page = 1
        while offset < textView.contentSize.height, page <= 6 {
            textView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            textView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: directory.appendingPathComponent("ios-\(name)-\(page).png"))
            offset += size.height - 80
            page += 1
        }
    }

    static func makeWindow(size: CGSize, style: UIUserInterfaceStyle) throws -> (UIWindow, MobileTextView) {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        let controller = UIViewController()
        let textView = MobileTextView()
        controller.view = textView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        textView.documentURL = fixtureURL
        textView.load(try String(contentsOf: fixtureURL, encoding: .utf8))
        textView.layoutIfNeeded()
        return (window, textView)
    }
}

/// Load and scroll timings on a document of about 100 KB, the fixture
/// repeated. Reported, not asserted: the simulator is not the phone.
@MainActor
struct ScrollTimingProbeTests {
    @Test
    func timesLoadingAndScrollingA100KBDocument() async throws {
        guard RenderProbeTests.probeDirectory != nil else { return }
        let fixture = try String(contentsOf: RenderProbeTests.fixtureURL, encoding: .utf8)
        let source = String(repeating: fixture + "\n", count: max(1, 100_000 / fixture.utf8.count))
        let (window, textView) = try RenderProbeTests.makeWindow(size: CGSize(width: 402, height: 874), style: .light)
        defer { window.isHidden = true }

        let clock = ContinuousClock()
        let load = clock.measure {
            textView.load(source)
            textView.layoutIfNeeded()
        }
        let layoutAll = clock.measure {
            textView.paperLayoutManager.ensureLayout(for: textView.textContainer)
        }
        var steps: [Duration] = []
        var offset: CGFloat = 0
        while offset < textView.contentSize.height - 874, steps.count < 400 {
            offset += 120
            steps.append(clock.measure {
                textView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                textView.layoutIfNeeded()
                textView.layer.displayIfNeeded()
                for view in textView.subviews { view.layer.displayIfNeeded() }
            })
        }
        let sorted = steps.sorted()
        let report = """
        bytes \(source.utf8.count)
        load+style \(load)
        full layout \(layoutAll)
        scroll steps \(steps.count), median \(sorted[sorted.count / 2]), p95 \(sorted[sorted.count * 95 / 100]), max \(sorted.last!)
        """
        print("PAPER-TIMING\n" + report)
        try report.write(to: RenderProbeTests.probeDirectory!.appendingPathComponent("ios-timing.txt"), atomically: true, encoding: .utf8)
    }
}
