# Open files in Paper from ChatGPT

Add Paper to the desktop app’s **Open** menu with its name and icon using a custom file handler. This adds a separate Paper entry alongside **Default app**. It does not change your macOS file associations.

The configuration mechanism below was inspected in ChatGPT for macOS `26.901.41123` (build `7942`) on `2026.09.05`. The configuration was written and validated locally; the menu itself was not visually verified. Availability may differ between ChatGPT/Codex desktop versions.

## Ask your agent

Paste this into a local agent that can edit your desktop configuration:

```text
Add Paper to my ChatGPT/Codex desktop app’s Open menu using
desktop.custom_file_handlers.paper in ~/.codex/config.toml.

First check that my installed desktop app supports custom_file_handlers
and locate Paper.app. Back up the configuration and preserve all existing
settings. If the Paper handler already exists, update it rather than
adding a duplicate TOML table.

Use label "Paper", command "/usr/bin/open", args ["-a", the absolute
path to Paper.app], input "path", and supports_ssh false. Extract
Paper.app/Contents/Resources/AppIcon.icns to a PNG with sips and embed
the PNG as a data:image/png;base64 URI in the icon field.

Validate the resulting TOML. Check that the Open menu shows Paper and
its icon, and that selecting it for a Markdown file opens Paper. If you
cannot inspect the menu, say so. Do not modify the application bundle.
```

## Manual setup

These steps assume Paper is installed at `/Applications/Paper.app` and the desktop app reads `~/.codex/config.toml`.

1. Back up `~/.codex/config.toml` before editing it.
2. Save a PNG copy of Paper’s icon in a persistent location:

   ```sh
   mkdir -p "$HOME/.codex/icons"
   sips -s format png -Z 128 "/Applications/Paper.app/Contents/Resources/AppIcon.icns" --out "$HOME/.codex/icons/paper.png"
   ```

3. Add this table to `~/.codex/config.toml`. Replace `YOUR_USERNAME` with your macOS account name. Use an absolute icon path; do not use `~` or `$HOME` inside the TOML string. If the table already exists, edit it in place.

   ```toml
   [desktop.custom_file_handlers.paper]
   label = "Paper"
   command = "/usr/bin/open"
   args = ["-a", "/Applications/Paper.app"]
   input = "path"
   supports_ssh = false
   icon = "/Users/YOUR_USERNAME/.codex/icons/paper.png"
   ```

   The handler appends the selected file path to `args`, so the resulting command opens that file in Paper. An embedded PNG data URI is also accepted for `icon` and avoids depending on a separate icon file.

4. Reopen the **Open** menu for a local Markdown file. If Paper does not appear, restart the desktop app. Select **Paper** and confirm that the document opens.

## Troubleshooting and removal

- **Default app still appears:** expected. That entry has a generic label and icon; the custom handler adds a separate **Paper** entry.
- **Paper is missing:** check for duplicate TOML tables, confirm your desktop version supports `custom_file_handlers`, and restart the app.
- **The icon is missing:** confirm the PNG exists at the exact absolute path in `icon`.
- **The file does not open:** check the Paper application path in `args`. The handler is for local files; it does not support SSH paths.
- **Remove the entry:** remove only the `[desktop.custom_file_handlers.paper]` table and its fields, leaving the surrounding configuration intact. Reopen the menu or restart the app.

To make Paper open Markdown files throughout macOS, follow [Default app for Markdown](../README.md#default-app-for-markdown).
