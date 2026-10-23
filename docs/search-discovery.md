# Search discovery

Browser Bridge uses static HTML so migration instructions and support limits are available without JavaScript. Search discovery work follows Google's [SEO starter guide](https://developers.google.com/search/docs/fundamentals/seo-starter-guide): descriptive page titles, useful original instructions, crawlable links and canonical URLs. Search rankings, indexing and GitHub stars are outcomes, not guaranteed product features.

A sitemap lists canonical pages, excluding interactive route/filter query variants. Each shareable page has its own description and social preview metadata. Structured product data reflects the free Mac beta; it contains no invented ratings or reviews.

This is a GitHub Pages project at `/browser-bridge/`. A `robots.txt` inside that project directory is not the host's root robots file and would not control Google crawling. Do not advertise such a file as an indexing fix. Submit the project sitemap in a verified URL-prefix Search Console property instead.

## Search Console

Property: `https://ritvikchunamari.github.io/browser-bridge/`.
Sitemap: `https://ritvikchunamari.github.io/browser-bridge/sitemap.xml`.

Ownership was verified with Google’s public HTML file and the five-page sitemap was submitted on 23 October 2026. The initial sitemap report said “Couldn’t fetch”; a separate Google live URL test then confirmed “URL is available to Google.” The sitemap and all five canonical pages return HTTP 200. The homepage indexing request was accepted into Google’s priority crawl queue. Sitemap processing and actual search indexing remain separate outcomes; neither is claimed complete here. Search Console measures indexing/search queries; this site does not embed analytics or transmit browser migration data to Google. Keep Google verification tokens at their expected public path only; never commit account credentials.

## Community discovery

The website and README invite visitors to star the GitHub repository if the project is useful. Repository description, topics and social preview should accurately describe local browser migration on Mac. No purchased stars, fabricated testimonials or automated outreach are used. Community announcements require a separate explicit request identifying where to post.

## Release verification

Universal beta v0.3.1 contains both arm64 and x86_64 slices in the app and native host, with macOS 14 deployment targets and strict signatures checked per slice. Intel runtime remains unverified and guided-only. 24 Swift and 14 helper tests pass on arm64; 16 website visitor checks and two metadata tests pass. Guides were inspected at desktop/mobile sizes and checked for keyboard access and horizontal overflow. Both Standards and Spec review axes reported zero actionable findings. Public release asset hashes match local archives. GitHub Pages deployment succeeded, and public source bytes match the integration source apart from expected shell executable-mode differences and private task records.
