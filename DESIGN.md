# Browser Bridge

Native macOS Human Interface Guidelines (`FormStyle.grouped` / macOS System Settings) are the visual authority. Operate mode: reusable migration manager, inset grouped rows (`Color(nsColor: .windowBackgroundColor)` and `Color(nsColor: .controlBackgroundColor)`), `1px` `separatorColor` dividers, `24×24pt` rounded-rect icon badges, native AppKit `.toggleStyle(.switch)` switches, `.buttonStyle(.borderedProminent)` primary actions, `.monospacedDigit()` tabular counts, sidebar navigation, and system SF Pro typography. System accent blue is used strictly for interactive controls. No decorative background blobs, nested cards inside cards, or marketing kicker badges.

The original logo joins two simplified browser windows through a central bridge. Canonical vector artwork is `Assets/Brand/logo.svg`; `logo-mono.svg` supports inherited ink color. `scripts/brand.swift` generates transparent PNG, white mark, Mac icon and ICNS assets locally. Use the mark intact with clear surrounding space; do not substitute vendor browser logos or add decorative gradients.

The main workflow stays code-led and native. Demo data is visibly labeled and cannot export. Desktop web and helper surfaces inherit the restrained macOS dark system tokens (`#1e1e1e` canvas, `#28282b` group surface, `1px` subtle borders, `tabular-nums`, focus rings, and `prefers-reduced-motion` support).
