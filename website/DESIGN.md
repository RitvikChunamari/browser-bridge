---
name: Browser Bridge product website
description: A dark editorial world for a familiar browsing life in motion.
colors:
  canvas: "#111810"
  surface: "#1b291b"
  text: "#f1f3e9"
  leaf: "#c2f181"
  leaf-hover: "#dcffb2"
  action-ink: "#15200e"
  outline-hover: "#24351c"
  outline-hover-text: "#e0ffc0"
  border: "#44533e"
  section-border: "#3b4736"
  logo-green: "#2e6143"
  logo-tile: "#d7ebc5"
typography:
  display:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(52px, 6.8vw, 96px)"
    fontWeight: 420
    lineHeight: 1.04
    letterSpacing: "-.035em"
  headline:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(39px, 4.3vw, 62px)"
    fontWeight: 420
    lineHeight: 1.04
    letterSpacing: "-.035em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: "16px"
    lineHeight: 1.55
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: "15px"
    fontWeight: 600
rounded:
  control: "7px"
  select: "8px"
  demonstration: "16px"
spacing:
  action-gap: "24px"
  navigation-gap: "30px"
  mobile-section: "55px"
  section: "100px"
components:
  button-primary:
    backgroundColor: "{colors.leaf}"
    textColor: "{colors.action-ink}"
    rounded: "{rounded.control}"
    padding: "13px 22px"
  button-primary-hover:
    backgroundColor: "{colors.leaf-hover}"
    textColor: "{colors.action-ink}"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.leaf}"
    rounded: "{rounded.control}"
    padding: "13px 22px"
  button-outline-hover:
    backgroundColor: "{colors.outline-hover}"
    textColor: "{colors.outline-hover-text}"
---

# Design System: Browser Bridge website

## Overview

**Creative North Star: "Your familiar world, in motion."** This phrase describes the implemented direction; it is not a separate user-approved brand slogan.

This website is a distinct visual world from the native SwiftUI app. Its confirmed direction is dark and expressive, retaining the original connected-window mark. Warm editorial serif headlines, deep green surfaces, leaf-green actions and precise system-sans controls make moving browsers feel personal while keeping capability boundaries legible.

**Key Characteristics:**
- Large, human headlines paired with restrained functional typography.
- Wide editorial sections with deliberate changes in density.
- An interactive transfer runway as the signature illustration, using synthetic data.
- Quiet olive rules and tonal layering rather than floating cards.

**The Surface Boundary Rule.** Apply this contract to `website/` only. Product capabilities remain governed by `../PRODUCT.md`; the native application's design contract remains separate.

Evidence: extracted from `style.css`, `index.html`, `app.js` and `assets/mark.svg`. This document records source evidence, not a claim of completed rendered or accessibility verification. The stylesheet is the implementation source; frontmatter captures its reusable visual values.

## Colors

Primary: leaf is the action, emphasis, progress and focus color. Leaf-hover brightens filled calls to action. The original logo-green remains inside the supplied connected-window asset on its pale logo-tile; do not recolor the mark to the action accent.

Neutral: canvas carries the page, text carries primary copy, and surface groups the demonstration and privacy spread. Border and section-border separate content quietly. Supporting text uses a range of muted sage tones already present in the stylesheet; no new semantic status palette is established.

**The Green Roles Rule.** Preserve the distinction between the original identity green and the brighter leaf action color. Do not turn all text or surfaces into accents.

## Typography

Fraunces is self-hosted from `assets/Fraunces.ttf` with its OFL license alongside it. Headings use a variable weight, tight tracking and balanced wrapping; italic leaf emphasis is reserved for short phrases. Body, navigation, tables and controls use the platform sans-serif stack. No remote font service is required.

At the narrow breakpoint, the main headline uses a fixed 53px size and 1.08 line height. The closing headline has its own larger fluid scale. Small helper and ledger labels range from 12–14px; explanatory copy ranges from 15–24px, with the privacy statement larger still. Preserve these distinctions instead of applying display styling to controls.

## Layout

The page has a 1440px maximum width, centered with percentage gutters. Desktop gutters are 5%; narrow layouts use 6%. Hero copy is an asymmetric two-column composition; the transfer runway spans its full width. Explanatory and privacy sections pair a headline column with a prose column. The support ledger is intentionally dense and flat.

At 900px, gaps and vertical section spacing tighten. At 620px, main content columns stack, section spacing uses the mobile-section token, one navigation link is hidden, and the transfer runway becomes two browser columns with its bridge below. The ledger retains a 570px minimum width inside a focusable horizontal-scroll region. Do not compress its columns into unreadable text.

**The Varied Rhythm Rule.** Alternate open editorial prose, the contained demonstration, and the ledger. Avoid turning every section into the same card grid.

## Elevation & Depth

Depth comes from surface tone and fine borders. The current website uses no box shadows, glass blur or floating panels. Privacy receives a full-section tonal background; the demonstration uses a bounded surface. Retain this quiet hierarchy.

## Shapes

Controls have gently softened corners; the demonstration has the larger radius token and clips its contents. Route selectors are an intentional exception: transparent, square-edged fields with an underline. Small circles serve step numbers and the simulation indicator. The connected-window mark retains its existing geometry.

## Components

- **Actions:** filled leaf download links and outlined simulation buttons share generous horizontal spacing and a minimum 50px height. Hover changes color; keyboard focus uses a 3px leaf outline with 6px offset. Disabled simulation controls fade and show a waiting cursor.
- **Navigation:** compact text links remain visually quiet. The brand combines the preserved mark and a sans-serif wordmark. A skip link moves into view on focus.
- **Transfer runway:** labeled native selectors flank a branching SVG path. The illustrative folder list is static. Only activation animates the path; the result is announced through a polite live region. Identical source and destination disable simulation. Route changes cancel an active simulation and reset its result.
- **Route state:** source, destination and family filter are reflected in URL query parameters. Safari routes explicitly limit the simulation to bookmark HTML. No browser access is implied by the illustration.
- **Support ledger:** a native select filters eleven browser rows by family and updates a polite browser count. The table uses header associations, fine horizontal rules and no enclosing row cards. Chrome source and Brave destination rows show the exact-version automatic route; all other versions/directions/pairs remain guided beta.
- **Motion:** the path runs for roughly 1.1 seconds after activation. Reduced-motion preference removes its animation and completes the simulated result without delay; smooth anchor scrolling also becomes immediate.

**The Honest Demonstration Rule.** Keep the simulation label, illustrative-data disclaimer and route-specific boundaries visible. Do not style a simulated result as proof of a real transfer.

## Do's and Don'ts

Do:
- Preserve the supplied green connected-window logo and its pale tile.
- Use leaf green for meaningful emphasis, actions and visible focus.
- Keep section rhythm, serif hierarchy and dense support information distinct.
- Retain local assets, reduced-motion behavior and keyboard access.
- Keep the beta state, exact verified versions and guided-route boundaries beside relevant actions.

Don't:
- Apply this dark website world to the native app without a separate direction decision.
- Add remote fonts, paid services, analytics or backend dependencies to this static surface.
- Replace the ledger with generic marketing cards or add decorative shadows.
- Imply that the website can read browser data or verify an automatic route.
- Present planned platforms or connected transfer behavior as released capability.
