# Using Paper

Everything Paper does beyond opening a file and letting you write. The [README](../README.md) is the short version.

## Writing

Markdown renders as you type. Off the paragraph you are in, the syntax hides: `**bold**` reads as **bold**, a heading loses its `#`, a link shows its text, a list its bullets. Put the caret in a paragraph and its syntax comes back to edit. The file on disk is always exactly what you typed.

Spelling is checked as you type, and grammar can be (`spelling`, `grammar`); code, math, and link addresses never are.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘B / ⌘I / ⌘U / ⌘⇧X / ⌘E | toggle `**bold**`, `*italic*`, `<u>underline</u>`, `~~strikethrough~~`, `` `code` `` around the selection or word |
| ⌘K | add a link, destination from the clipboard when it holds a URL |
| ⌘F / ⌘G / ⇧⌘G | find; next and previous match. Return and ⇧Return step from the field, Esc closes |
| click / ⌘-click | open a link |
| double-click an image | open it in Quick Look |
| click the corner icon on a `$$` formula | open it enlarged in Quick Look |
| paste or drop an image | saved beside the document, inserted as `![](…)` |
| ⌘+ / ⌘− / ⌘0 | zoom the view in and out, back to actual size; click the badge at the top right to type a percentage; per machine, never written to the config |
| ⇧⌘E / ⌘P | export the document as a PDF, or print it, as it reads here on Letter or A4 pages |
| ⇧⌘P | pin the document to the menu bar, or unpin it |
| ⌥⌘C | copy the file's path as plain text |
| ⌘, | settings |

## The window

The window has no title bar. Rest the pointer in the top-left corner and a pill shows the file's name, with the full path as its tooltip; click it to copy the path or the name, or to show the file in Finder.

## Images

An image alone on its line, `![alt](file.png)`, draws in the page, scaled down to the width of the text when it is wider. Double-click it to open it in Quick Look, with ← → across the document's images.

Pasting or dropping an image into an unsaved document asks you to save first. Images go beside the document by default; set `image.paste.directory = assets` to use a relative subfolder instead. Undo removes the inserted Markdown, but keeps the image file.

## Math

LaTeX between dollar signs is typeset in place, the way GitHub reads it. `$E = mc^2$` in a line sits on the text's baseline; a `$$ … $$` block, on one line or several, or a ```` ```math ```` fence, is centred on its own. Click into the paragraph to edit the source; nothing below it moves. Prices and paths stay prose: there is no space just inside either `$` of a formula and no digit after its closer, so `$5 and $10` and `$HOME` read as typed, and `\$` is a literal dollar. Hover a display formula and click the icon in its corner to open it enlarged. Math exports and prints as vector type.

Typesetting is [SwiftMath](https://github.com/mgriebling/SwiftMath), which covers most of the LaTeX math people write day to day (fractions, roots, sums and integrals, matrices, `cases`, Greek, accents, `\text`); a command it lacks, like `\operatorname`, shows its source with the error. `math.font` picks the typeface, `math.scale` the size, `color.math` the ink, and `math = off` leaves every dollar as typed. Settings (⌘,) has the same under Math.

## Menu bar and pins

Paper keeps an item in the menu bar, beside the clock, listing your pinned documents, then the recent ones, then New and Open. Pin the front document with File ▸ Pin Document… (⇧⌘P) or from the file pill's menu; it asks for a name, the file name by default. Settings ▸ Menu bar renames, reorders, and unpins them, and `menu.bar = off` takes the item away.

## Themes and presets

`theme` picks one of the built-in themes (enso, apple, paper, slate, mono, spatial), each with a light and a dark pair that follows the system. Any colour can be overridden with a `color.*` key, and Settings can save the current colours as a theme of your own, a file in `themes/` beside the config. A preset is a saved set of every setting, applied from Settings in one step.

## Default app for Markdown

`paper --set-default` makes double-clicking a `.md` or `.markdown` file open Paper; so does *Make Default* in Settings (⌘,) under CLI. By hand: select any Markdown file in Finder, press ⌘I (Get Info), choose Paper under *Open with*, and click *Change All*….

## Configuration

Settings live in `$XDG_CONFIG_HOME/paper/config` when set, otherwise `~/.config/paper/config`. The file is written as a commented template on first launch and applied live to open windows whenever it is saved. Settings (⌘,) edits the same file. Selected defaults are shown below; the generated template documents every key.

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
print.font.size = 10
print.margin = 64
math = on
math.font = latin-modern
math.scale = 1
```
