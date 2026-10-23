# Browser Bridge website

Static project site; no install, build step or paid dependency. From the repository root:

```sh
python3 -m http.server 8874 --directory website
```

Open http://localhost:8874. Publish the **contents** of `website/` as a GitHub Pages artifact. All local asset references are relative, so the same files work at `/browser-bridge/`. Parent release integration owns the Pages workflow/settings.

`index.html` owns release copy and links. `app.js` owns the explicitly simulated route demo and support filter. It reads no browser data and makes no network requests. Only Chrome 156.0.8078.48 → Brave 156.1.98.60 is marked verified automatic; other versions, directions and pairs stay guided. Update copy and download links together with a release, never infer verified vendor support from family fixtures.

The visitor seam is `Tests/Website/visitor-checks.js`: load its async function in a Playwright Page runner against the local server. It tests share links, support filtering, Safari limitations, same-browser prevention, keyboard simulation, reduced-motion behavior, skip navigation, four viewport widths and runtime errors. Visual review also requires desktop/mobile screenshots.

Fraunces variable font is self-hosted from https://github.com/google/fonts/tree/main/ofl/fraunces (SIL OFL; retained in `assets/OFL.txt`). The original project logo is MIT-licensed with the source. No vendor logos, telemetry, remote fonts or runtime dependencies.
