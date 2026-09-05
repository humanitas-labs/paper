# Paper — Documentation

| Doc | What it covers |
| --- | --- |
| [chatgpt.md](chatgpt.md) | Add Paper and its icon to the ChatGPT/Codex desktop Open menu |
| [build.md](build.md) | Building and testing from source (XcodeGen, xcodebuild) |
| [architecture.md](architecture.md) | How the editor is put together — document lifecycle, TextKit pipeline, styling |
| [decisions/](decisions/) | Architecture decision records |

## Decisions

| ADR | Decision |
| --- | --- |
| [001](decisions/001-native-editor.md) | Native macOS document lifecycle with an AppKit editing core |
| [002](decisions/002-contextual-syntax-concealment.md) | Conceal Markdown syntax during layout, preserving the source exactly |
| [003](decisions/003-markdown-resource-resolution.md) | Resolve Markdown resources relative to the saved document |
| [004](decisions/004-zero-advance-control-glyphs.md) | Use zero-advance control glyphs for concealed syntax; revises ADR-002 |

`assets/` holds the README screenshot; `references/` holds visual references the design steers by.
