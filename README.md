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

## What it does

- Markdown renders as you type; the syntax comes back in the paragraph you are editing, and the file stays exactly as typed. [Writing](docs/guide.md#writing)
- Images alone on a line draw in the page; paste or drop one to save it beside the document. [Images](docs/guide.md#images)
- LaTeX math, inline `$…$` and display `$$ … $$`, typeset in place. [Math](docs/guide.md#math)
- Find, zoom, and export or print as a PDF that reads like the page. [Shortcuts](docs/guide.md#shortcuts)
- Pinned documents in the menu bar. [Menu bar and pins](docs/guide.md#menu-bar-and-pins)
- Built-in themes in light and dark, your own colours, and presets. [Themes and presets](docs/guide.md#themes-and-presets)
- Opens Markdown by default if you want it to. [Default app](docs/guide.md#default-app-for-markdown)

## Configuration

Everything lives in one plain-text file, `~/.config/paper/config`, applied live whenever it is saved; Settings (⌘,) edits the same file, and the file documents every key. See [Configuration](docs/guide.md#configuration).

## More

- [User guide](docs/guide.md)
- [Add Paper to ChatGPT’s Open menu](docs/chatgpt.md)
- [Build and test](docs/build.md)
- [Architecture](docs/architecture.md)

## Supporters

Paper is free forever, but these are the people who helped make it possible. If you want to join them, a <a href="https://buymeacoffee.com/dremnik"><img src="landing/bmc.svg" height="15" alt="">&nbsp;coffee</a> is always appreciated :)

- Roman Pronskiy
- Ross Sylvester
- Will Tholke
