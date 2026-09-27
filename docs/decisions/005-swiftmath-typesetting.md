# ADR-005 :: SwiftMath for LaTeX typesetting

Status: Accepted

Date recorded: `2026.09.27`

## Decision

- LaTeX math (#80) is typeset by [SwiftMath](https://github.com/mgriebling/SwiftMath), an MIT Swift port of iosMath, added as a Swift package. It is Paper's first package dependency.
- The version is pinned exactly to 1.7.3 in `project.yml`. The unreleased main branch at `1d2c908` replaces the typesetter with a tokenizing one that drops the spacing between atoms (`\sin x` sets as `sinx`, `\quad` vanishes); any upgrade is checked against the render probe first.
- `MathStore` is the only file that imports SwiftMath. The typesetter is internal to the package, so formulas are laid out through an offscreen `MTMathUILabel` and drawn from its display list into the view's own context.

## Rationale

SwiftMath draws with Core Text into a `CGContext`. Formulas therefore draw in the theme's ink and follow the dark pair, export to PDF as vector text through the existing print surface, and report the ascent, descent, and width that band reservation and inline baselines need. Typesetting is synchronous, about 0.5 to 2 ms per formula, and cached.

Rejected: KaTeX or MathJax in JavaScriptCore or a `WKWebView`. They cover more LaTeX, but are asynchronous, hand back SVG or a bitmap that needs another conversion, and bring a web runtime into a native editor. A hand-written typesetter was not considered viable.

Costs accepted: the package bundles about 7 MB of math fonts, of which Paper uses Latin Modern; commands outside SwiftMath 1.7.3's set, such as `\operatorname`, show as parse errors with their source.

## Design Implications

- Math is presentation only, like every other rendering: the source stays in storage, marked `.mathSource`, and saving is untouched.
- Display math reserves a band through paragraph spacing, like block images, so revealing its source never changes document height.
- SwiftMath strokes rules (fraction bars, radicals) through `NSBezierPath`, which draws into the current `NSGraphicsContext`. Any drawing path for formulas must have one set, as `drawBackground(in:)` and the print surface do.

## When to Revisit

- SwiftMath publishes a release that fixes atom spacing and adds commands Paper's documents need.
- Documents need LaTeX coverage SwiftMath lacks (macros, `align` numbering) often enough that a web engine's cost is worth it.
- The bundled fonts' size matters for distribution; vendoring the package with Latin Modern alone would cut it.
