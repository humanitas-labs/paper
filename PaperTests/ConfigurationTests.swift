import Foundation
import Testing
@testable import Paper

struct ConfigurationTests {
    @Test
    func templateParsesToDefaults() {
        #expect(Configuration.parse(Configuration.template) == Configuration())
    }

    @Test
    func emptyAndCommentOnlyTextYieldDefaults() {
        #expect(Configuration.parse("") == Configuration())
        #expect(Configuration.parse("# nothing\n\n   \n# = still a comment\n") == Configuration())
    }

    @Test
    func parsesKeysWithWhitespaceQuotesAndCase() {
        let text = """
          Font.Family =  "New York"
        font.size=15.4
        line.height = '1.6'
        paragraph.spacing = 8
        measure = 720
        heading.weight = SemiBold
        """
        let config = Configuration.parse(text)
        #expect(config.fontFamily == "New York")
        #expect(config.fontSize == 15.4)
        #expect(config.lineHeight == 1.6)
        #expect(config.paragraphSpacing == 8)
        #expect(config.measure == 720)
        #expect(config.headingWeight == 600)
    }

    @Test
    func invalidValuesFallBackAndOutOfRangeValuesClamp() {
        let config = Configuration.parse("""
        font.size = large
        line.height = nan
        heading.weight = heavyish
        measure = 10
        font.family =
        unknown.key = 1
        no equals sign here
        """)
        #expect(config.fontSize == Configuration().fontSize)
        #expect(config.lineHeight == Configuration().lineHeight)
        #expect(config.headingWeight == Configuration().headingWeight)
        #expect(config.measure == Configuration.measureRange.lowerBound)
        #expect(config.fontFamily == Configuration().fontFamily)
    }

    @Test
    func mergingUpdatesValuesInPlaceAndAppendsMissingKeys() {
        var config = Configuration()
        config.fontSize = 15.4
        config.headingWeight = 700
        let text = "# keep me\nfont.size = 14   \nmystery = 1\n\nheading.weight = medium\n"
        let merged = config.merged(into: text)
        #expect(merged.hasPrefix("# keep me\nfont.size = 15.4\nmystery = 1\n\nheading.weight = 700\n"))
        #expect(merged.contains("\nfont.family = New York\n"))
        #expect(Configuration.parse(merged) == config)

        // Merging into the template only touches value lines.
        var defaults = Configuration()
        defaults.measure = 700
        let templated = defaults.merged(into: Configuration.template)
        #expect(templated == Configuration.template.replacingOccurrences(of: "measure = 640", with: "measure = 700"))
    }

    @Test
    func laterKeysOverrideEarlierOnes() {
        #expect(Configuration.parse("font.size = 12\nfont.size = 18").fontSize == 18)
    }
}

struct ThemeTests {
    @Test
    func hexParsesNormalizesAndRejects() {
        #expect(HexColor.normalized("#f6f3ec") == "#F6F3EC")
        #expect(HexColor.normalized(" 1B1916 ") == "#1B1916")
        #expect(HexColor.normalized("#FFF") == nil)
        #expect(HexColor.blend("#000000", over: "#FFFFFF", alpha: 0.5) == "#808080")
        #expect(HexColor.blend("#FF0000", over: "#FFFFFF", alpha: 0.13) == "#FFDEDE", "a 13% wash of red over white")
        #expect(HexColor.blend("nope", over: "#FFFFFF", alpha: 0.5) == nil)
        #expect(HexColor.normalized("#GGGGGG") == nil)
        #expect(HexColor.normalized("") == nil)
        let c = HexColor.components("#FF8000")!
        #expect(c.red == 1 && c.green == 128.0 / 255 && c.blue == 0)
        #expect(HexColor.string(red: 1, green: 128.0 / 255, blue: 0) == "#FF8000")
    }

    @Test
    func themeKeysParseAndOverridesApply() {
        let config = Configuration.parse("""
        theme = Slate
        color.ink = #102030
        color.canvas =
        color.ink.dark = nonsense
        """)
        #expect(config.theme == "slate")
        #expect(config.ink == "#102030")
        #expect(config.canvas == nil)
        #expect(config.inkDark == nil, "invalid hex inherits the theme")
        let slate = Theme.builtIn(named: "slate")!
        #expect(config.palette(over: slate.palette).ink == "#102030")
        #expect(Configuration.parse("letter.spacing = -0.4").letterSpacing == -0.4)
        #expect(Configuration.parse("window.width = 1200\nwindow.height = 100").windowWidth == 1200)
        #expect(Configuration.parse("window.width = 1200\nwindow.height = 100").windowHeight == 520, "clamped")
        #expect(Configuration.parse("letter.spacing = 9").letterSpacing == 3, "clamped")
        #expect(Configuration.parse("heading.weight = 540").headingWeight == 540)
        #expect(Configuration.parse("font.weight = light").fontWeight == 300)
        #expect(Configuration.parse("font.weight = 2000").fontWeight == 900, "clamped")
        #expect(!Configuration().fontSmoothing, "smoothing is off by default")
        #expect(Configuration.parse("font.smoothing = on").fontSmoothing)
        #expect(Configuration.parse("font.smoothing = ON\nfont.smoothing = maybe").fontSmoothing == true, "an unknown value keeps the last good one")
        #expect(Configuration.parse("font.smoothing = off").entries.contains { $0.key == "font.smoothing" && $0.value == "off" })
        #expect(Configuration.parse("image.corner.radius = 0").imageCornerRadius == 0, "square")
        #expect(Configuration.parse("image.corner.radius = 99").imageCornerRadius == 40, "clamped")
        #expect(Configuration.parse("image.corner.radius = round").imageCornerRadius == 12, "default matches the code band")
        #expect(Configuration.parse("print.font.size = 9\nprint.margin = 72").printFontSize == 9)
        #expect(Configuration.parse("print.font.size = 9\nprint.margin = 72").printMargin == 72)
        #expect(Configuration.parse("print.font.size = 1").printFontSize == 6, "clamped")
        #expect(Configuration.parse("print.margin = big").printMargin == 64, "default")
        #expect(Configuration.parse("spelling = off").spelling == false)
        #expect(Configuration.parse("grammar = no").grammar == false)
        #expect(Configuration.parse("spelling = sometimes").spelling == true, "default")
        #expect(Configuration.parse("grammar = off").spelling == true, "independent")
        #expect(Configuration.parse("list.indent = 0").listIndent == 0, "on the margin")
        #expect(Configuration.parse("list.indent = 9").listIndent == 4, "clamped")
        #expect(Configuration.parse("list.indent = far").listIndent == 0.8, "default")
        #expect(config.palette(over: slate.palette).canvas == slate.palette.canvas)
        #expect(config.palette(over: slate.palette).inkDark == slate.palette.inkDark)
        #expect(Configuration.parse("theme = nope").theme == "nope", "an unknown name is kept for a theme file added later")
        #expect(Configuration.parse("theme =").theme == "enso", "a blank name keeps the default")
        #expect(Configuration.parse("theme = spatial").theme == "spatial")
        #expect(Configuration.parse("theme = Apple").theme == "apple")
        // Pre-0.2 configs spell the dark pair with a suffix; they resolve
        // to the renamed themes.
        #expect(Configuration.parse("theme = Spatial-Dark").theme == "spatial")
        #expect(Configuration.parse("theme = apple-dark").theme == "apple")
        let spatial = Theme.builtIn(named: "spatial")!
        #expect(spatial.palette.canvas != spatial.palette.canvasDark, "spatial now has a light appearance")
        #expect(Configuration().palette(over: Theme.enso.palette) == Theme.enso.palette)
    }

    @Test
    func userThemeFallsBackPerKeyAndWritesOutItsColours() {
        let sepia = Theme.user(named: "Sepia", text: "color.canvas = #F4ECD8\ncolor.ink = #5B4636\n")
        #expect(sepia.name == "sepia" && sepia.title == "Sepia" && !sepia.isBuiltIn)
        #expect(sepia.palette.canvas == "#F4ECD8")
        #expect(sepia.palette.canvasDark == Theme.enso.palette.canvasDark, "missing keys fall back to Enso")
        #expect(sepia.palette.overrides.fileText == """
        color.canvas = #F4ECD8
        color.ink = #5B4636
        color.canvas.dark = #191B1D
        color.ink.dark = #F4F9FA

        """)
        #expect(Theme.user(named: "x", text: "").palette.canvas == Theme.enso.palette.canvas)
        #expect(Theme.user(named: "x", text: "").palette.selection == nil, "optional tones are not inherited")
    }

    @Test
    func elementTokensParseEmitAndLayerOverAThemeFile() {
        let config = Configuration.parse("""
        color.ink.muted = #b00020
        color.selection.dark = #334455
        color.rule = bad
        """)
        #expect(config.colorOverrides.inkMuted == "#B00020")
        #expect(config.colorOverrides.selectionDark == "#334455")
        #expect(config.colorOverrides.rule == nil)
        #expect(config.canvas == nil)
        let text = config.merged(into: Configuration.template)
        #expect(text.contains("\ncolor.ink.muted = #B00020\n"))
        #expect(text.contains("\ncolor.rule =\n"))
        #expect(Configuration.parse(text) == config)

        let theme = Theme.user(named: "loud", text: "color.ink.muted = #FF0000\ncolor.code.background = #EEEEEE\n")
        #expect(theme.palette.inkMuted == "#FF0000")
        #expect(theme.palette.inkMutedDark == nil, "the dark form derives when a theme leaves it out")
        let inUse = config.palette(over: theme.palette)
        #expect(inUse.inkMuted == "#B00020", "the config's override wins")
        #expect(inUse.codeBackground == "#EEEEEE", "the theme's token stays")
        #expect(theme.palette.overrides.fileText.contains("color.code.background = #EEEEEE"))
        #expect(!theme.palette.overrides.fileText.contains("color.rule"), "unset tokens are not written")
    }

    @Test
    func labelInkIsAThemeTokenWithEnsoSettingIt() {
        #expect(Theme.enso.palette.inkLabel == "#68737E")
        #expect(Theme.enso.palette.inkLabelDark == "#68737E")
        #expect(Theme.builtIn(named: "paper")?.palette.inkLabel == nil, "other themes derive it from the ink")
        let theme = Theme.user(named: "tinted", text: "color.ink.label = #445566\ncolor.ink.label.dark = #99AABB\n")
        #expect(theme.palette.inkLabel == "#445566")
        #expect(theme.palette.inkLabelDark == "#99AABB")
        #expect(theme.palette.overrides.fileText.contains("color.ink.label = #445566\n"))
        #expect(Configuration.template.contains("\ncolor.ink.label =\n"))
    }

    @Test
    func mergedWritesEmptyOverridesAsBareKeys() {
        var config = Configuration()
        config.theme = "slate"
        config.ink = "#123456"
        let text = config.merged(into: Configuration.template)
        #expect(text.contains("\ntheme = slate\n"))
        #expect(text.contains("\ncolor.ink = #123456\n"))
        #expect(text.contains("\ncolor.canvas =\n"))
        #expect(Configuration.parse(text) == config)
    }
}

@MainActor
struct ConfigurationStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config")
    }

    @Test
    func startWritesTemplateWhenMissingAndLoadsIt() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        #expect(try String(contentsOf: url, encoding: .utf8) == Configuration.template)
        #expect(store.current == Configuration())
    }

    @Test
    func startKeepsAnExistingFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "font.size = 21".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        #expect(store.current.fontSize == 21)
        #expect(try String(contentsOf: url, encoding: .utf8) == "font.size = 21")
    }

    @Test
    func renamingAPresetMovesItsFileAndFollowsTheActiveName() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        store.savePreset(named: "Draft")
        #expect(store.activePreset == "Draft")

        #expect(store.renamePreset(named: "Draft", to: "Final"))
        #expect(store.presets.contains("Final") && !store.presets.contains("Draft"))
        #expect(store.activePreset == "Final")
        #expect(store.preset(named: "Final") == store.current)

        store.savePreset(named: "Other", Configuration())
        #expect(!store.renamePreset(named: "Final", to: "Other"), "an existing name is refused")
        #expect(!store.renamePreset(named: "Final", to: "a/b"), "path separators are refused")
        #expect(store.activePreset == "Final")
    }

    @Test(arguments: [true, false])
    func reloadsWhenTheFileChanges(atomically: Bool) async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        #expect(store.current.fontSize == 15)

        try "font.size = 19\nmeasure = 700".write(to: url, atomically: atomically, encoding: .utf8)
        let deadline = ContinuousClock.now + .seconds(3)
        while store.current.fontSize != 19, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.current.fontSize == 19)
        #expect(store.current.measure == 700)

        // A second change after a replacement proves the watch re-armed.
        try "font.size = 23".write(to: url, atomically: atomically, encoding: .utf8)
        let secondDeadline = ContinuousClock.now + .seconds(3)
        while store.current.fontSize != 23, ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.current.fontSize == 23)
    }

    @Test
    func writePersistsIntoTheFilePreservingComments() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        var config = Configuration()
        config.lineHeight = 1.6
        store.write(config)
        #expect(store.current == config)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("line.height = 1.6"))
        #expect(text.hasPrefix("# Paper configuration."))
        #expect(Configuration.parse(text) == config)
    }

    @Test
    func presetsSaveApplyAndDelete() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        #expect(store.presets.isEmpty)
        #expect(store.matchingPreset == nil)

        var large = Configuration()
        large.fontSize = 18
        large.fontFamily = "Georgia"
        store.write(large)
        #expect(store.savePreset(named: "Reading"))
        #expect(store.savePreset(named: "Defaults", Configuration()))
        #expect(!store.savePreset(named: " "))
        #expect(!store.savePreset(named: "a/b"))
        #expect(store.presets == ["Defaults", "Reading"])
        #expect(store.matchingPreset == "Reading")
        #expect(FileManager.default.fileExists(atPath: store.presetURL(named: "Reading").path))

        #expect(store.applyPreset(named: "Defaults"))
        #expect(store.current == Configuration())
        #expect(store.matchingPreset == "Defaults")
        #expect(Configuration.parse(try String(contentsOf: url, encoding: .utf8)) == Configuration())

        var tweaked = store.current
        tweaked.lineHeight = 1.6
        store.write(tweaked)
        #expect(store.matchingPreset == "Defaults", "editing after applying writes into the preset")
        #expect(store.preset(named: "Defaults") == tweaked)
        #expect(store.preset(named: "Reading") == large, "other presets are untouched")

        #expect(!store.applyPreset(named: "Missing"))
        store.deletePreset(named: "Reading")
        #expect(store.presets == ["Defaults"])
    }

    @Test
    func themeFilesAreListedResolvedAndShadowBuiltIns() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        #expect(store.themes == Theme.builtIn)
        #expect(FileManager.default.fileExists(atPath: store.themesDirectoryURL.path))

        var config = Configuration()
        config.theme = "sepia"
        store.write(config)
        #expect(store.resolvedTheme == Theme.enso, "an unknown name resolves to Enso")
        #expect(store.current.theme == "sepia", "and is kept in the config")

        try "color.canvas = #F4ECD8\ncolor.ink = #5B4636\n".write(to: store.themeURL(named: "Sepia"), atomically: true, encoding: .utf8)
        store.loadThemes()
        #expect(store.themes.map(\.name) == ["enso", "apple", "paper", "slate", "mono", "spatial", "sepia"])
        #expect(store.resolvedTheme.title == "Sepia")
        #expect(store.palette.canvas == "#F4ECD8")
        #expect(store.palette.inkDark == Theme.enso.palette.inkDark)

        config.ink = "#000000"
        store.write(config)
        #expect(store.palette.ink == "#000000", "config overrides layer on a file theme")
        #expect(store.palette.canvas == "#F4ECD8")

        try "color.ink = #FF0000\n".write(to: store.themeURL(named: "paper"), atomically: true, encoding: .utf8)
        store.loadThemes()
        #expect(store.themes.filter { $0.name == "paper" }.count == 1)
        #expect(store.theme(named: "paper")?.isBuiltIn == false, "a file named like a built-in shadows it")
        #expect(store.theme(named: "Paper")?.palette.ink == "#FF0000")
        store.deleteTheme(named: "paper")
        #expect(store.theme(named: "paper")?.isBuiltIn == true, "deleting the file restores the built-in")
        store.deleteTheme(named: "slate")
        #expect(store.theme(named: "slate") != nil, "built-ins cannot be deleted")
    }

    @Test
    func savingAThemeWritesTheColoursInUseAndClearsOverrides() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        var config = Configuration()
        config.theme = "slate"
        config.ink = "#102030"
        store.write(config)
        let expected = store.palette

        #expect(!store.saveTheme(named: "a/b"))
        #expect(store.saveTheme(named: "Night Ink"))
        #expect(store.current.theme == "night ink")
        #expect(store.current.colorOverrides.isEmpty)
        #expect(store.resolvedTheme.title == "Night Ink")
        #expect(store.palette == expected, "the colours in use do not change")
        #expect(try String(contentsOf: store.themeURL(named: "Night Ink"), encoding: .utf8) == expected.overrides.fileText)
        #expect(Configuration.parse(try String(contentsOf: url, encoding: .utf8)).theme == "night ink")
    }

    @Test
    func themeFileChangesRecolourOpenWindows() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        var config = Configuration()
        config.theme = "sepia"
        store.write(config)
        nonisolated(unsafe) var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Configuration.didChangeNotification, object: store, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try "color.canvas = #F4ECD8\n".write(to: store.themeURL(named: "sepia"), atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now + .seconds(3)
        while store.palette.canvas != "#F4ECD8", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.palette.canvas == "#F4ECD8")
        #expect(posts == 1, "a theme change is posted like a config change")
    }

    @Test
    func activePresetReceivesEditsAsTheyAreMade() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigurationStore(fileURL: url)
        defer { ConfigurationStore.forgetActivePreset(for: url) }
        store.start()
        defer { store.deletePreset(named: "Work") }

        store.savePreset(named: "Work")
        #expect(store.activePreset == "Work")

        var edited = store.current
        edited.fontSize = 17
        store.write(edited)
        #expect(store.activePreset == "Work", "editing keeps the preset active")
        #expect(store.preset(named: "Work")?.fontSize == 17, "the edit is written into the preset")
        #expect(store.matchingPreset == "Work")

        // Switching presets must not write the new values into the old one.
        var other = store.current
        other.fontSize = 21
        store.savePreset(named: "Other", other)
        store.applyPreset(named: "Other")
        #expect(store.current.fontSize == 21)
        #expect(store.preset(named: "Work")?.fontSize == 17)
        store.applyPreset(named: "Work")
        #expect(store.current.fontSize == 17)
        store.deletePreset(named: "Other")

        let reopened = ConfigurationStore(fileURL: url)
        reopened.start()
        #expect(reopened.activePreset == "Work", "persists across launches")

        store.deletePreset(named: "Work")
        #expect(store.activePreset == nil)
    }

    @Test
    func applyPostsOnlyOnChange() {
        let store = ConfigurationStore(fileURL: temporaryFile())
        nonisolated(unsafe) var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Configuration.didChangeNotification, object: store, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.apply(Configuration())
        var changed = Configuration()
        changed.fontSize = 16
        store.apply(changed)
        store.apply(changed)
        #expect(posts == 1)
    }
}
