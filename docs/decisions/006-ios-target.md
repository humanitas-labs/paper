# ADR-006 :: An iOS target sharing the Mac's engine

Status: Accepted

Date recorded: `2026.11.23`

## Decision

- Paper runs on iPhone and iPad as a second app target, `PaperMobile`, in the same repository and `project.yml`. It is built for direct installation on Andrew's devices, not for release.
- The iOS target compiles the Mac's engine from `Paper/` by an explicit file list: the styler, the layout manager, tables, math, images, appearance, configuration, the document model, and the Foundation-only helpers. Nothing Mac-only is compiled in by accident.
- `Paper/Platform/Platform.swift` maps the AppKit names the shared files use (`NSColor`, `NSFont`, `NSImage`, geometry) onto UIKit's on iOS, with a few spelling shims, so the shared files read the same on both platforms. Passages with no iOS counterpart (pointer and tooltip attributes, spelling-mark filtering on the layout manager, font-manager lookups) are fenced with `#if os(macOS)`.
- The styler and `PrintStyle.Page.apply` take a `StyledSurface`, a small protocol for what they need of a text view: storage, container, selection, typing attributes, the document URL, and the print and image hooks. On the Mac `NSTextView` conforms, reaching `PaperTextView`'s parts by cast as the styler did before; on iOS `MobileTextView` conforms.
- The iOS writing surface is `MobileTextView`, a `UITextView` on TextKit 1 built with `init(frame:textContainer:)` over a `PaperLayoutManager`. The page's decorations draw in a `DecorationView` behind the text, because `UITextView` has no `drawBackground(in:)`.

## Rationale

Paper's hard work happens in TextKit 1: glyph concealment through the glyph-generation delegate, table rows through the line-fragment delegate, bands through paragraph spacing. TextKit 1 has the same classes and delegates on iOS, so the engine carries over. A compile probe on 2026.11.23 found 94 errors in 19 files, all shallow; the port needed about 200 changed lines in the shared files, and the Mac's behavior is unchanged.

Rejected: a local Swift package for the shared engine. It draws a cleaner, compiler-enforced boundary, but moves about 20 files and touches every test's `@testable import`, and the iOS app has not yet earned that churn. Revisit when it has.

Rejected: TextKit 2 on iOS. It is UIKit's default, but Paper's concealment, substitution and table layout are written against TextKit 1's glyph model, which TextKit 2 does not expose. Rewriting them would be a second engine.

Rejected: a web view. It would not share the engine at all.

Costs accepted: Appearance has two font-lookup paths; the iOS one finds a static family's nearest weight through a weight trait rather than AppKit's font manager. The system spelling checker on iOS cannot be filtered per range, so code may show spelling marks. `DecorationView` began as a copy of the Mac's drawing; a shared page renderer is planned (`.plan/ios.md`, IOS-06).

## Design Implications

- A shared file must compile for both platforms. New AppKit use in one goes through the shim, or behind `#if os(macOS)`.
- The styler sees text views only through `StyledSurface`. A new need of the styler is a new protocol member, implemented on both surfaces.
- `MobileTextView` must never read `textLayoutManager`: on UIKit that switches the view to TextKit 2 and drops Paper's layout manager.
- SwiftMath strokes rules into the current graphics context on both platforms; on iOS a drawing path for formulas must have one current, as `UIView.draw(_:)` does and as `MathStore`'s preview pushes.
- The iOS config is `config` in the app's Documents folder, visible in the Files app; the Mac's stays in `~/.config/paper/`.

## When to Revisit

- The iOS app becomes something Andrew uses daily: move the shared engine into a package and extract the page renderer.
- A future iOS deprecates or degrades TextKit 1 in `UITextView`. The Mac carries the same exposure in `NSTextView`.
- Paper is to be released on iOS: signing, distribution, and the public repository's contents become decisions of their own.
