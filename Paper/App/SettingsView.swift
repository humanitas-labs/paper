import AppKit
import SwiftUI

/// Controls for every configuration key. Changes are written straight into
/// the config file, so the window and the file never disagree; editing the
/// file by hand updates these controls the same way.
struct SettingsView: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var isNamingPreset = false
    @State private var isRenamingPreset = false
    @State private var presetName = ""
    @State private var isNamingTheme = false
    @State private var themeName = ""

    private let families = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private func binding<Value>(_ keyPath: WritableKeyPath<Configuration, Value>) -> Binding<Value> {
        Binding(
            get: { store.current[keyPath: keyPath] },
            set: { value in
                var configuration = store.current
                configuration[keyPath: keyPath] = value
                store.write(configuration)
            }
        )
    }

    /// The active preset, or "None". Choosing a preset writes its values
    /// through to the config file; it stays selected while edited.
    private var presetSelection: Binding<String> {
        Binding(
            get: { store.activePreset ?? "" },
            set: { name in
                if !name.isEmpty { store.applyPreset(named: name) }
            }
        )
    }

    /// The configured theme name. A name no theme has (its file was
    /// removed) is listed so the picker still shows what the config says.
    private var themeSelection: Binding<String> {
        Binding(
            get: { store.current.theme },
            set: { name in
                var configuration = store.current
                configuration.theme = name
                store.write(configuration)
            }
        )
    }

    /// A colour well bound to one hex override; nil shows the theme's colour.
    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<Configuration, String?>, themeValue: KeyPath<Palette, String>) -> some View {
        colorRow(title, keyPath, current: store.current[keyPath: keyPath] ?? store.resolvedTheme.palette[keyPath: themeValue])
    }

    /// The selection highlight rows. A theme may set no selection tone; the
    /// well then shows the ink over the canvas at the opacity the editor
    /// draws it, so a change starts from what is on screen.
    private func selectionRow(_ title: String, _ keyPath: WritableKeyPath<Configuration, String?>, dark: Bool) -> some View {
        let palette = store.resolvedTheme.palette
        let themeTone = dark ? palette.selectionDark : palette.selection
        let derived = HexColor.blend(dark ? palette.inkDark : palette.ink, over: dark ? palette.canvasDark : palette.canvas, alpha: 0.13)
        return colorRow(title, keyPath, current: store.current[keyPath: keyPath] ?? themeTone ?? derived ?? palette.ink)
    }

    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<Configuration, String?>, current: String) -> some View {
        func write(_ hex: String) {
            var configuration = store.current
            configuration[keyPath: keyPath] = hex
            store.write(configuration)
        }
        let binding = Binding<Color>(
            get: { Color(nsColor: Appearance.color(hex: current)) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                write(HexColor.string(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
            }
        )
        return HStack {
            ColorPicker(title, selection: binding, supportsOpacity: false)
            HexField(value: current, commit: write)
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Reset to Defaults") { store.write(Configuration()) }
                    Spacer()
                    Button("Open Config File") { NSWorkspace.shared.open(store.fileURL) }
                }
                Text(store.fileURL.path(percentEncoded: false))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Presets") {
                Picker("Preset", selection: presetSelection) {
                    Text("None").tag("")
                    ForEach(store.presets, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button("Save as New Preset…") {
                        presetName = ""
                        isNamingPreset = true
                    }
                    Spacer()
                    Button("Rename…") {
                        presetName = store.activePreset ?? ""
                        isRenamingPreset = true
                    }
                    .disabled(store.activePreset == nil)
                    Button("Delete", role: .destructive) {
                        if let name = store.activePreset { store.deletePreset(named: name) }
                    }
                    .disabled(store.activePreset == nil)
                }
            }

            Section("Theme") {
                Picker("Theme", selection: themeSelection) {
                    let builtIn = store.themes.filter(\.isBuiltIn)
                    let custom = store.themes.filter { !$0.isBuiltIn }
                    if store.theme(named: store.current.theme) == nil {
                        Text("\(store.current.theme) (missing)").tag(store.current.theme)
                    }
                    if custom.isEmpty {
                        ForEach(builtIn) { Text($0.title).tag($0.name) }
                    } else {
                        Section("Built-in") { ForEach(builtIn) { Text($0.title).tag($0.name) } }
                        Section("Custom") { ForEach(custom) { Text($0.title).tag($0.name) } }
                    }
                }
                colorRow("Canvas", \.canvas, themeValue: \.canvas)
                colorRow("Ink", \.ink, themeValue: \.ink)
                colorRow("Canvas (dark)", \.canvasDark, themeValue: \.canvasDark)
                colorRow("Ink (dark)", \.inkDark, themeValue: \.inkDark)
                selectionRow("Selection", \.selection, dark: false)
                selectionRow("Selection (dark)", \.selectionDark, dark: true)
                HStack {
                    Button("Save as Theme…") {
                        themeName = ""
                        isNamingTheme = true
                    }
                    Spacer()
                    Button("Delete Theme", role: .destructive) { store.deleteTheme(named: store.current.theme) }
                        .disabled(store.resolvedTheme.isBuiltIn)
                    Button("Use Theme Colours") {
                        var configuration = store.current
                        configuration.colorOverrides = Palette.Overrides()
                        store.write(configuration)
                    }
                    .disabled(store.current.colorOverrides.isEmpty)
                }
                Text("Themes are files in \(store.themesDirectoryURL.path(percentEncoded: false)); a file named like a built-in replaces it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Type") {
                Picker("Typeface", selection: binding(\.fontFamily)) {
                    if !families.contains(store.current.fontFamily) {
                        Text(store.current.fontFamily).tag(store.current.fontFamily)
                    }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                numberRow("Size", binding(\.fontSize), in: Configuration.fontSizeRange, unit: "pt")
                numberRow("Weight", binding(\.fontWeight), in: Configuration.weightRange, unit: "")
                numberRow("Line height", binding(\.lineHeight), in: Configuration.lineHeightRange, unit: "×")
                numberRow("Letter spacing", binding(\.letterSpacing), in: Configuration.letterSpacingRange, unit: "pt")
                numberRow("Paragraph spacing", binding(\.paragraphSpacing), in: Configuration.paragraphSpacingRange, unit: "pt")
                numberRow("Measure", binding(\.measure), in: Configuration.measureRange, unit: "pt")
                numberRow("Heading weight", binding(\.headingWeight), in: Configuration.weightRange, unit: "")
                Toggle("Font smoothing", isOn: binding(\.fontSmoothing))
            }

            Section("Text") {
                Toggle("Spelling", isOn: binding(\.spelling))
                Toggle("Grammar", isOn: binding(\.grammar))
                Text("Checking as you type, underlined; code and link addresses are never checked.")
                    .font(.caption)
            }

            Section("Lists") {
                numberRow("Indent", binding(\.listIndent), in: Configuration.listIndentRange, unit: "×")
                Text("How far bullets, numbers, and task circles sit from the text margin, in font sizes.")
                    .font(.caption)
            }

            Section("Images") {
                numberRow("Corner radius", binding(\.imageCornerRadius), in: Configuration.imageCornerRadiusRange, unit: "pt")
            }


            Section("Window") {
                numberRow("Width", binding(\.windowWidth), in: Configuration.windowWidthRange, unit: "pt")
                numberRow("Height", binding(\.windowHeight), in: Configuration.windowHeightRange, unit: "pt")
                Text("Applies to new windows; each window keeps its own size afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Print and PDF") {
                numberRow("Body size", binding(\.printFontSize), in: Configuration.printFontSizeRange, unit: "pt")
                numberRow("Margin", binding(\.printMargin), in: Configuration.printMarginRange, unit: "pt")
                Text("Pages made by Print (⌘P) and Export as PDF (⇧⌘E). Lines wrap to the page at this size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CLI") {
                CommandLineToolRow()
                DefaultApplicationRow()
            }

            Section("Updates") {
                Toggle("Check for updates", isOn: binding(\.updateCheck))
                Text("Once a day on launch, asks GitHub for the latest release and shows a download icon in the welcome window when it is newer. Off never makes the request.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .background(SettingsWindowConfigurator())
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { store.savePreset(named: presetName) }
                .disabled(!ConfigurationStore.isValidPresetName(presetName))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current settings under this name and makes it the active preset. An existing name is replaced.")
        }
        .alert("Save Theme", isPresented: $isNamingTheme) {
            TextField("Name", text: $themeName)
            Button("Save") { store.saveTheme(named: themeName) }
                .disabled(!ConfigurationStore.isValidPresetName(themeName))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the colours in use as a theme file under this name and selects it. An existing theme of that name is replaced.")
        }
        .alert("Rename Preset", isPresented: $isRenamingPreset) {
            TextField("Name", text: $presetName)
            Button("Rename") {
                if let name = store.activePreset { store.renamePreset(named: name, to: presetName) }
            }
            .disabled(!ConfigurationStore.isValidPresetName(presetName))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the active preset's file. A name already in use is refused.")
        }
    }

    private func numberRow(
        _ title: String,
        _ value: Binding<Double>,
        in range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        HStack {
            Slider(value: value, in: range) { Text(title) }
            NumberField(value: value.wrappedValue, range: range) { value.wrappedValue = $0 }
            Text(unit).frame(width: 18, alignment: .leading)
        }
    }
}

/// A number field beside a slider. The text is a draft while it has focus,
/// committed on Return or when focus leaves, then clamped to the range;
/// a value field bound straight to the config wrote every keystroke, so
/// typing 14 over 40 went 4, 8 (the floor), 81, 40, and never took 14.
/// Text that is not a number snaps back to the current value.
private struct NumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

    var body: some View {
        TextField("Value", text: $draft)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .focused($focused)
            .onAppear { draft = Self.format.format(value) }
            .onChange(of: value) { _, new in if !focused { draft = Self.format.format(new) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
            .onSubmit(submit)
    }

    private func submit() {
        if let typed = Self.parse(draft) {
            let clamped = min(max(typed, range.lowerBound), range.upperBound)
            if clamped != value { commit(clamped) }
            draft = Self.format.format(clamped)
        } else {
            draft = Self.format.format(value)
        }
    }

    /// The typed number, accepting a locale decimal or a plain period.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = try? Double(trimmed, format: format) { return value }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

/// A hex colour field beside a colour well. Edits commit on Return or when
/// focus leaves; invalid text snaps back to the current value.
private struct HexField: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Hex", text: $draft)
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
            .onSubmit(submit)
    }

    private func submit() {
        if let hex = HexColor.normalized(draft), hex != value {
            commit(hex)
        }
        draft = HexColor.normalized(draft) ?? value
    }
}

/// Lets the Settings window appear on top of a full-screen document instead
/// of switching to the desktop space.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> HostView { HostView(frame: .zero) }
    func updateNSView(_ view: HostView, context: Context) { view.configureWindow() }

    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            window?.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
        }
    }
}

/// Paper as the app that opens Markdown files, and a button to make it so.
private struct DefaultApplicationRow: View {
    @State private var isDefault = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isDefault ? "Paper opens Markdown files" : "Default app for Markdown")
            Spacer()
            Button("Make Default") {
                busy = true
                Task {
                    do { try await DefaultApplication.makeDefault(); error = nil }
                    catch { self.error = error.localizedDescription }
                    isDefault = DefaultApplication.isDefault
                    busy = false
                }
            }
            .disabled(busy || isDefault)
        }
        Text("What a double-click on a .md or .markdown file opens; `paper --set-default` does the same from the terminal.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
        Color.clear.frame(height: 0).task { isDefault = DefaultApplication.isDefault }
    }
}

/// The `paper` command: where it is, and one button to put it there, fix
/// it, or take it away.
private struct CommandLineToolRow: View {
    @ObservedObject private var tool = CommandLineTool.shared
    @State private var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                if let detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button(action: act) { Text(action) }
                .disabled(busy || !actionable)
        }
        Text("`paper notes.md` opens a document from the terminal, creating it when it is new; agents can use it to open documents for you.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error = tool.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
        Color.clear.frame(height: 0).task { await tool.refresh() }
    }

    private var headline: String {
        switch tool.status {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .broken: "Broken: the app has moved since the command was installed"
        case .stale: "Points to another copy of Paper"
        case .foreign: "Another paper command is on the PATH"
        }
    }

    private var detail: String? {
        tool.status.link?.path
    }

    private var action: String {
        switch tool.status {
        case .notInstalled: "Install"
        case .broken, .stale: "Repair"
        case .installed, .foreign: "Uninstall"
        }
    }

    private var actionable: Bool {
        if case .foreign = tool.status { return false }
        return true
    }

    private func act() {
        busy = true
        Task {
            if tool.status.needsInstall {
                await tool.install()
            } else {
                await tool.uninstall()
            }
            busy = false
        }
    }
}
