import Foundation

/// Owns the live configuration: loads the file, writes the template when it
/// is missing, and reloads whenever the file changes on disk. Every window
/// reads `current` and listens for `Configuration.didChangeNotification`.
@MainActor
final class ConfigurationStore: ObservableObject {
    static let shared = ConfigurationStore(fileURL: defaultFileURL)

    /// `$XDG_CONFIG_HOME/paper/config`, or `~/.config/paper/config`.
    static var defaultFileURL: URL {
        configurationBase.appendingPathComponent("paper", isDirectory: true).appendingPathComponent("config")
    }

    private static var configurationBase: URL {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }

    @Published private(set) var current = Configuration()
    /// Names of the saved presets, sorted, refreshed whenever the presets
    /// directory changes.
    @Published private(set) var presets: [String] = []
    /// The preset last applied or saved. Edits made while it is active are
    /// written into it, so the preset and the live settings never drift;
    /// cleared when the preset is deleted. Persisted per config file across
    /// launches.
    @Published private(set) var activePreset: String?
    /// The built-in themes followed by the user's theme files, refreshed
    /// whenever the themes directory changes. A user theme shadows a
    /// built-in of the same name.
    @Published private(set) var themes: [Theme] = Theme.builtIn
    let fileURL: URL
    /// Whether `start()` had to create the config file: the app's first
    /// launch, or a reset. The welcome document opens on it.
    private(set) var isFirstLaunch = false

    /// `presets/` beside the config file; one file per preset in the same
    /// `key = value` format, named after the preset.
    var presetsDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("presets", isDirectory: true)
    }

    /// `themes/` beside the config file; one file per theme holding
    /// `color.*` keys, named after the theme.
    var themesDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
    }

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var presetsSource: DispatchSourceFileSystemObject?
    private var themesSource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
        activePreset = UserDefaults.standard.string(forKey: activePresetKey)
    }

    private var activePresetKey: String { "paper.activePreset:\(fileURL.path)" }

    /// Removes the remembered active preset for a config file. Tests use it
    /// so temporary stores leave nothing behind in the user's defaults.
    static func forgetActivePreset(for fileURL: URL) {
        UserDefaults.standard.removeObject(forKey: "paper.activePreset:\(fileURL.path)")
    }

    private func setActivePreset(_ name: String?) {
        activePreset = name
        UserDefaults.standard.set(name, forKey: activePresetKey)
    }

    /// Creates the config file from the template if absent, loads it, and
    /// starts watching. Safe to call more than once.
    func start() {
        ensureFileExists()
        reload()
        loadPresets()
        loadThemes()
        watch()
    }

    // MARK: - Themes

    func themeURL(named name: String) -> URL {
        themesDirectoryURL.appendingPathComponent(name.trimmingCharacters(in: .whitespaces))
    }

    /// Reads every theme file and rebuilds `themes`; a colour change is
    /// posted like a config change so open windows recolour.
    func loadThemes() {
        let before = palette
        let names = (try? FileManager.default.contentsOfDirectory(atPath: themesDirectoryURL.path)) ?? []
        let user: [Theme] = names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                guard let text = try? String(contentsOf: themeURL(named: name), encoding: .utf8) else { return nil }
                return Theme.user(named: name, text: text)
            }
        let shadowed = Set(user.map(\.name))
        themes = Theme.builtIn.filter { !shadowed.contains($0.name) } + user
        if palette != before {
            NotificationCenter.default.post(name: Configuration.didChangeNotification, object: self)
        }
    }

    func theme(named name: String) -> Theme? {
        themes.first { $0.name == Theme.canonicalName(name) }
    }

    /// The configured theme, or Apple when nothing has that name.
    var resolvedTheme: Theme {
        theme(named: current.theme) ?? .enso
    }

    /// The colours in use: the resolved theme under the config's overrides.
    var palette: Palette {
        current.palette(over: resolvedTheme.palette)
    }

    /// Writes the colours in use to `themes/<name>` as a theme file, then
    /// selects it and clears the overrides that were folded into it.
    @discardableResult
    func saveTheme(named name: String) -> Bool {
        guard Self.isValidPresetName(name) else { return false }
        try? FileManager.default.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
        guard (try? palette.overrides.fileText.write(to: themeURL(named: name), atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        loadThemes()
        var configuration = current
        configuration.theme = Theme.canonicalName(name)
        configuration.colorOverrides = Palette.Overrides()
        write(configuration)
        return true
    }

    func deleteTheme(named name: String) {
        guard let theme = theme(named: name), !theme.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: themeURL(named: theme.title))
        loadThemes()
    }

    // MARK: - Presets

    /// A preset name is a file name: non-empty, no path separators.
    static func isValidPresetName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.hasPrefix(".")
    }

    func presetURL(named name: String) -> URL {
        presetsDirectoryURL.appendingPathComponent(name.trimmingCharacters(in: .whitespaces))
    }

    func loadPresets() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: presetsDirectoryURL.path)) ?? []
        presets = names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if let activePreset, !presets.contains(activePreset) {
            setActivePreset(nil)
        }
    }

    func preset(named name: String) -> Configuration? {
        guard let text = try? String(contentsOf: presetURL(named: name), encoding: .utf8) else { return nil }
        return Configuration.parse(text)
    }

    /// The saved preset whose values equal the live configuration, if any.
    var matchingPreset: String? {
        presets.first { preset(named: $0) == current }
    }

    /// Saves `configuration` (the live one by default) under `name`,
    /// replacing any preset of that name.
    @discardableResult
    func savePreset(named name: String, _ configuration: Configuration? = nil) -> Bool {
        guard Self.isValidPresetName(name) else { return false }
        let target = configuration ?? current
        try? FileManager.default.createDirectory(at: presetsDirectoryURL, withIntermediateDirectories: true)
        let text = target.merged(into: Configuration.template)
        guard (try? text.write(to: presetURL(named: name), atomically: true, encoding: .utf8)) != nil else { return false }
        loadPresets()
        if configuration == nil { setActivePreset(name.trimmingCharacters(in: .whitespaces)) }
        return true
    }

    /// Writes the preset's values into the live configuration and the config
    /// file. Later edits are written into the preset as well.
    @discardableResult
    func applyPreset(named name: String) -> Bool {
        guard let configuration = preset(named: name) else { return false }
        // Activate first so the write does not land in the previous preset.
        setActivePreset(name)
        write(configuration)
        return true
    }

    /// Renames a preset's file, keeping it active if it was. A new name that
    /// is invalid or already taken leaves everything as it is.
    @discardableResult
    func renamePreset(named name: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard Self.isValidPresetName(trimmed), trimmed != name,
              !presets.contains(trimmed),
              (try? FileManager.default.moveItem(
                at: presetURL(named: name), to: presetURL(named: trimmed)
              )) != nil else { return false }
        if activePreset == name { setActivePreset(trimmed) }
        loadPresets()
        return true
    }

    func deletePreset(named name: String) {
        try? FileManager.default.removeItem(at: presetURL(named: name))
        if activePreset == name { setActivePreset(nil) }
        loadPresets()
    }

    /// Replaces the live configuration directly. Used by tests and by the
    /// reload path; posts the change notification only when something differs.
    func apply(_ configuration: Configuration) {
        guard configuration != current else { return }
        current = configuration
        NotificationCenter.default.post(name: Configuration.didChangeNotification, object: self)
    }

    /// Applies a configuration and writes it into the file, preserving the
    /// file's comments and layout, and into the active preset when its values
    /// differ. The resulting watch events reload identical values and are
    /// no-ops.
    func write(_ configuration: Configuration) {
        apply(configuration)
        ensureFileExists()
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? Configuration.template
        try? configuration.merged(into: existing).write(to: fileURL, atomically: true, encoding: .utf8)
        if let activePreset, preset(named: activePreset) != configuration {
            savePreset(named: activePreset, configuration)
        }
    }

    func reload() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        apply(Configuration.parse(text))
    }

    func ensureFileExists() {
        try? FileManager.default.createDirectory(at: presetsDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        isFirstLaunch = true
        try? Configuration.template.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Watching

    /// Editors save either in place (a write event on the file) or by
    /// replacing it (a rename/delete on the file and a write on the
    /// directory). Both are watched, and the file watch is re-armed after a
    /// replacement so the new inode is followed.
    private func watch() {
        directorySource?.cancel()
        directorySource = makeSource(for: fileURL.deletingLastPathComponent(), events: .write) { [weak self] in
            self?.scheduleReload()
        }
        armFileSource()

        presetsSource?.cancel()
        presetsSource = makeSource(for: presetsDirectoryURL, events: .write) { [weak self] in
            self?.loadPresets()
        }

        themesSource?.cancel()
        themesSource = makeSource(for: themesDirectoryURL, events: .write) { [weak self] in
            self?.scheduleThemeReload()
        }
    }

    private var themeReloadTask: Task<Void, Never>?

    /// A theme file saved by an editor produces a burst of directory events
    /// and may be mid-write on the first; coalesce them as the config is.
    private func scheduleThemeReload() {
        themeReloadTask?.cancel()
        themeReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.loadThemes()
        }
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(for: fileURL, events: [.write, .extend, .delete, .rename, .attrib]) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func makeSource(
        for url: URL,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Coalesces bursts of events (an atomic save produces several) into one
    /// reload, then re-arms the file watch in case the inode changed.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.reload()
            self.armFileSource()
        }
    }
}
