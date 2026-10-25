---
name: Browser Bridge product website
description: Restrained Apple dark editorial showcase for a native macOS browser migration utility.
colors:
  canvas: "#000000"
  surface: "#141416"
  surface-elevated: "#1d1d1f"
  text: "#f5f5f7"
  text-secondary: "#86868b"
  accent: "#0071e3"
  accent-link: "#2997ff"
  border: "rgba(255, 255, 255, 0.09)"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif"
    fontSize: "clamp(48px, 6vw, 84px)"
    fontWeight: 600
    lineHeight: 1.06
    letterSpacing: "-.03em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif"
    fontSize: "clamp(34px, 4vw, 54px)"
    fontWeight: 600
    lineHeight: 1.06
    letterSpacing: "-.03em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Segoe UI', sans-serif"
    fontSize: "17px"
    lineHeight: 1.47
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
    fontSize: "14px"
    fontWeight: 500
rounded:
  control: "10px"
  select: "8px"
  demonstration: "16px"
spacing:
  action-gap: "24px"
  navigation-gap: "28px"
  mobile-section: "55px"
  section: "96px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    padding: "12px 22px"
  button-outline:
    backgroundColor: "rgba(255, 255, 255, 0.06)"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "12px 22px"
---

# Design System: Browser Bridge website (v0.4.0)

## Overview

**Creative North Star: "Your familiar world, in motion."**

The product website uses a restrained Apple dark editorial system (`#000000` canvas, `#141416` and `#1d1d1f` surfaces, `#f5f5f7` primary text, `#86868b` secondary copy, `#0071e3` filled buttons, and `#2997ff` links) paired with clean SF Pro typography and `1px solid rgba(255, 255, 255, 0.09)` borders.

## Searchable guide surface
The guides use Read mode within the established dark identity. Article content is static HTML with a constrained 850px outer measure, 17px body text and generous heading spacing. Canonical paths end in .html and appear in sitemap.xml. Guide navigation and related links remain ordinary anchors. Social preview is a locally rendered 1200×630 PNG with the original mark; no remote media or font dependency. v0.4.0 is universal macOS 14+, with Apple-silicon exact-version automation, 1-Click Direct local profile migration, and explicitly unverified/guided Intel runtime.
