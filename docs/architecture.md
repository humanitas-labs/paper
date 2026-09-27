# Paper — Architecture

Last updated: `2026.09.27`

> Paper is a native macOS editor for ordinary UTF-8 Markdown files. The file is the only persistent document state. Rendering, configuration, and window state remain outside it.

## 1. System boundaries

| Component | Responsibility |
|---|---|
| `MarkdownDocument` | Decode and encode the source without transforming it |
| `PaperApp` | Own scenes, commands, and the native document lifecycle |
| `MarkdownEditor` | Bridge the SwiftUI document binding into AppKit |
| `PaperTextView` | Provide editing behavior and draw page decorations |
| `MarkdownSyntaxStyler` | Add temporary presentation attributes to the source |
| `PaperLayoutManager` | Conceal or substitute glyphs without changing storage |
| `MathStore` | Typeset and cache LaTeX formulas through SwiftMath |
| `ConfigurationStore` | Load, write, and watch user settings and presets |
| `Appearance` | Resolve configuration into fonts, spacing, and colours |

SwiftUI owns application composition. AppKit and TextKit 1 own the writing surface. The boundary between them is `MarkdownEditor`, an `NSViewRepresentable` that synchronizes plain text and the document URL.

## 2. Editor pipeline

```text
Markdown file
    ↕
MarkdownDocument
    ↕ SwiftUI binding
MarkdownEditor
    ↕
PaperTextView + MarkdownSyntaxStyler + PaperLayoutManager
```

The styler replaces presentation attributes across the in-memory text storage, then annotates recognized Markdown constructs. It does not replace source characters. Restyling waits while an input method holds marked text.

`PaperLayoutManager` turns concealed punctuation into zero-advance control glyphs outside the selected paragraphs and draws inline-code chips. Glyph substitution renders list markers and arrows without editing their source characters. `PaperTextView` draws block quotes, code blocks, thematic breaks, placeholders, and images around the laid-out text.

Block images use paragraph spacing to reserve a stable drawing band below the source line. The source remains present for selection, undo, copy, find, and saving. `ImageStore` decodes and downsamples local images off the main actor according to visible and prefetched demand. Its cache evicts least-recently-used unpinned entries under byte and entry budgets; visible images remain pinned and can exceed the byte budget. Image changes on disk invalidate cached content.

Display math (`$$ … $$` and `math` fences) follows the same pattern: the closing line's spacing reserves a band as tall as `MathStore` typesets the formula, whether the source is shown or not. Off the active paragraph the source conceals and the formula centres on the block and band together; on it the source shows and the formula previews in the band. The caret on any row reveals the whole block. Source that does not parse stays visible with the error in its band.

Inline math (`$…$`) is found right after code spans and set in the code font, so emphasis and the other inline passes skip it. Once lists and quotes have set the paragraph styles, each formula is typeset at the size that matches the x-height of the text beside it; off the active paragraph its first `$` reserves the formula's width (`.reservedWidth`, laid out as whitespace) and the rest conceals, and the text view draws the formula there on the baseline. A paragraph whose formula is taller than its lines gets a `minimumLineHeight` large enough for it in both states. `math.font`, `math.scale`, and `color.math` reach math through `Appearance` (`mathFont`, `mathSize`, `inlineMathSize`, `mathInk`); `MathStore` keys its cache and preview files by face, and `math = off` empties both math passes, so a `math` fence falls through to the code pass.

`PDFExporter` paginates the same pipeline: an offscreen `PaperTextView` marked as a print surface, styled at zoom 1 with a measure derived from the page (a 10 pt body between 64 pt margins), every image band pinned and decoded, no active paragraph, handed to an `NSPrintOperation` whose print info scales the column onto the paper. Export writes with a save job to a staging file moved into place; Print shows the panel over the same surface. Page breaks are AppKit's, between line fragments; the view's background pass draws each page's bands, rules, and images.

## 3. Invariants and configuration

- Saving must preserve the Markdown source exactly.
- Styling, concealment, substitution, and image rendering must not mutate the source string.
- Revealing syntax may change horizontal positions but must not change line or document height.
- Relative resources resolve from the saved Markdown file. Unsaved documents have no relative filesystem base.
- Opening a document must not fetch remote media automatically.
- The configuration file is the source of truth for user-tunable appearance values. The view zoom is the one exception: `Zoom` keeps a scale in `UserDefaults` per machine and `Appearance` multiplies the body size, measure, and margins by it, so the config and presets stay portable.

`ConfigurationStore` reads `key = value` settings from `$XDG_CONFIG_HOME/paper/config` or `~/.config/paper/config`. It preserves comments and unknown keys when writing, watches in-place and atomic saves, and posts a notification when effective values change. Presets use the same format in the adjacent `presets/` directory.

## 4. Decisions

| ID | Decision | Status |
|---|---|---|
| [ADR-001](decisions/001-native-editor.md) | Native document lifecycle and AppKit editing surface | Accepted |
| [ADR-002](decisions/002-contextual-syntax-concealment.md) | Contextual syntax concealment without source mutation | Accepted; mechanism revised by ADR-004 |
| [ADR-003](decisions/003-markdown-resource-resolution.md) | File-relative Markdown resource resolution | Accepted |
| [ADR-004](decisions/004-zero-advance-control-glyphs.md) | Zero-advance control glyphs for concealed syntax | Accepted |
| [ADR-005](decisions/005-swiftmath-typesetting.md) | SwiftMath for LaTeX typesetting | Accepted |
