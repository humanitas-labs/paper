# Paper

> A quiet, native markdown editor for macOS.

[Download for Mac](https://github.com/humanitas-labs/paper/releases/latest/download/Paper.dmg) · macOS 15 or later · free, MIT

![Paper showing its own README: a heading, an italic quote behind a rule, and a photograph of a raked rock garden](docs/assets/paper.png)

Paper is the simplest markdown editor imaginable.

There is nothing other than the text, by design.

In most editors, every button seems to invite you to do something other than write (or read). Here, there are no controls, and only one document opens per own window so you can focus with no distractions. Every choice has been made in favor of singular focus. Feel free to [fork](https://github.com/humanitas-labs/paper/fork) if that philosophy doesn’t suit your needs.

It is a descendant of Obsidian’s file > app philosophy. Apps are ephemeral, but files last—and you should own them. Everything is just a file on your computer.

Lastly, it is free and open. We will continue our campaign to make delightful software abundant again.

## CLI

> Meant to be used as a companion to agents. Let them open the files for you while you work.

`paper notes.md` opens a document from the terminal, creating it first when it doesn't exist yet; `paper` alone opens the app. Paper installs it on first launch when a directory you own is on your shell's PATH, such as `/opt/homebrew/bin` or `~/.local/bin`, and repairs the link when the app moves. When only `/usr/local/bin` is available, install it from Settings (⌘,) under CLI, which asks for your password; the same section shows where the command lives and removes it. The launcher itself is at `Paper.app/Contents/Resources/paper`.

Give this prompt to your agent of choice:

```
Add this to my global instructions:

> Markdown files are read in Paper, a native macOS editor. To show me a document, open it with `paper <file.md>`. Paper reloads from disk, so after the first open just keep editing the file. Never hard-wrap prose in Markdown: a paragraph is one source line.

Then check that the `paper` command works by writing a short note to a temporary file and opening it with `paper`. If the command is not found, tell me; it installs from Paper's Settings (⌘,) under CLI.

If I am someone who works in the terminal, also tell me that `paper <file>` opens any Markdown file from the shell, and that `paper --set-default` makes Paper the app that opens Markdown files when I double-click them. Ask before running that. If I am not, skip this.
```

## Default app for Markdown

`paper --set-default` makes double-clicking a `.md` or `.markdown` file open Paper; so does *Make Default* in Settings (⌘,) under CLI. By hand: select any Markdown file in Finder, press ⌘I (Get Info), choose Paper under *Open with*, and click *Change All*….

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘B / ⌘I / ⌘U / ⌘⇧X / ⌘E | toggle `**bold**`, `*italic*`, `<u>underline</u>`, `~~strikethrough~~`, `` `code` `` around the selection or word |
| ⌘K | add a link, destination from the clipboard when it holds a URL |
| ⌘F / ⌘G / ⇧⌘G | find; next and previous match. Return and ⇧Return step from the field, Esc closes |
| click / ⌘-click | open a link |
| double-click an image | open it in Quick Look |
| paste or drop an image | saved beside the document, inserted as `![](…)` |
| ⌘+ / ⌘− / ⌘0 | zoom the view in and out, back to actual size; click the badge at the top right to type a percentage; per machine, never written to the config |
| ⌘P | export the document as a PDF, as it reads here on Letter or A4 pages |
| ⌥⌘C | copy the file's path as plain text |
| ⌘, | settings |

The window has no title bar. Rest the pointer in the top-left corner and a pill shows the file's name, with the full path as its tooltip; click it to copy the path or the name, or to show the file in Finder.

Pasting or dropping an image into an unsaved document asks you to save first. Images go beside the document by default; set `image.paste.directory = assets` to use a relative subfolder instead. Undo removes the inserted Markdown, but keeps the image file.

## Configuration

Settings live in `$XDG_CONFIG_HOME/paper/config` when set, otherwise `~/.config/paper/config`. The file is written as a commented template on first launch and applied live to open windows whenever it is saved. Selected defaults are shown below; the generated template documents every key.

```ini
font.family = New York
font.size = 15
line.height = 1.2
paragraph.spacing = 11
letter.spacing = -0.02
font.smoothing = off
spelling = on
grammar = off
measure = 640
list.indent = 0.8
theme = enso
window.width = 1400
window.height = 876
```

## More

- [Add Paper to ChatGPT’s Open menu](docs/chatgpt.md)
- [Build and test](docs/build.md)
- [Architecture](docs/architecture.md)

## Supporters

Paper is free forever, but these are the people who helped make it possible. If you want to join them, a <a href="https://buymeacoffee.com/dremnik"><img src="landing/bmc.svg" height="15" alt="">&nbsp;coffee</a> is always appreciated :)

- Roman Pronskiy
- Ross Sylvester
- Will Tholke
