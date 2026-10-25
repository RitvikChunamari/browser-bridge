# Browser Bridge website

Static project site; no install, build step or paid dependency. From the repository root:

```sh
python3 -m http.server 8874 --directory website
```

Open http://localhost:8874. Publish the **contents** of `website/` as a GitHub Pages artifact. All local asset references are relative, so the same files work at `/browser-bridge/`. Parent release integration owns the Pages workflow/settings.

`index.html` owns release copy and links (v0.4.0-beta). `app.js` owns the explicitly simulated route demo and support filter. It reads no browser data and makes no network requests. Only Chrome 156.0.8078.48 → Brave 156.1.98.60 on Apple silicon is marked verified automatic in the connected connector table; 1-Click Direct local profile migration (`OneClickMigrator` / `bridge-migrate`) is documented alongside guided packages. Update copy and download links together with a release, never infer verified vendor support from family fixtures.

The visitor seam is `Tests/Website/visitor-checks.js`: load its async function in a Playwright Page runner against the local server. It tests share links, support filtering, Safari limitations, same-browser prevention, keyboard simulation, reduced-motion behavior, skip navigation, four viewport widths and runtime errors. Visual review also requires desktop/mobile screenshots.

Typography uses native system SF Pro (`-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text'`). Self-hosted font assets in `assets/` are retained with `assets/OFL.txt`. The original project logo is MIT-licensed with the source. No vendor logos, telemetry, remote fonts or runtime dependencies.

## Search and guide checks

Run `node --test Tests/Website/metadata.test.mjs` from the repository root. It checks unique canonical/OG metadata, sitemap coverage, static guide substance, local links, valid free-MIT SoftwareApplication schema, real 1200×630 PNG dimensions, architecture boundaries and absence of a misleading project-level robots file. Run `Tests/Website/visitor-checks.js` in the Playwright Page runner with the local server on port 8893 for the interactive seam.

Four static guides provide Mac migration planning, Zen-to-Dia limits, the tested Chrome-to-Brave route, and bookmarks HTML fallback. Official references were read from Chrome, Mozilla and Apple support; browser UI can change. The site makes no ranking or indexing promise. Social-card source is `assets/social-card.svg`, rendered locally into the committed PNG. Validate the deployed card URL after publication; localhost checks cannot prove a social network fetched the public preview. Intel runtime remains unverified and guided.
