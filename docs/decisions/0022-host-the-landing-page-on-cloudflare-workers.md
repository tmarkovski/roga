# 22. Host the landing page on Cloudflare Workers, as static files

Accepted on 2026-11-03. [Decision 34](0034-name-the-app-roga.md) chose Roga as the name, which settles what this record left open.

## Context

The app needs a page that says what it's going to be and that it's on its way. The domain is roga.sh, registered through Cloudflare, so its DNS is there already. The page has one job and nothing to log in to or save, and it should be quick to change.

We asked for Cloudflare Pages at first. Cloudflare's own documentation for Pages now tells new projects to start on Workers, which it calls its primary platform for building applications. What Workers can't do that matters is serve a domain whose nameservers are elsewhere, and roga.sh's aren't.

We considered these ways of building and deploying it:

- **A site generator such as Astro.** It earns its place when pages share a layout. With one page it adds a build step and dependencies to keep up to date, to produce the same HTML.
- **Workers Builds**, where Cloudflare connects to the repository and deploys it. It needs no token or workflow, and it can skip pushes that don't touch the site. But its settings live in Cloudflare's dashboard rather than in this repository, its logs can't be read with `gh`, and Cloudflare's GitHub app would need read access to the whole private repository.

## Decision

**The site is static files in `site/public`, with no build step.** That's one HTML page with its CSS inline, one script for the house, and system fonts, so nothing has to be downloaded from anywhere else. The Worker has no script of its own, and requests for static files are free.

**GitHub Actions deploys it.** [`site.yml`](../../.github/workflows/site.yml) runs only when `site/` changes, and on Linux. It validates the HTML and the Workers configuration, posts a preview on each pull request, deploys `main`, and then checks that roga.sh serves the page.

**The page calls the app Roga.** This only decides what the page says. The app, the repository and yaga.build keep their names until a name is chosen.

**The house walks along a line of commits.** "Coming soon" is the house on its way. It uses the same joints and the same stride as Push in [decision 21](0021-draw-the-houses-animations-from-joints.md), because the Waddle doesn't move its legs and so can't look like walking. The walk is ported to JavaScript and the floor's commits move under the feet at the speed the app works out, so the feet don't skate. Someone who asked for less motion, or who has no JavaScript, sees the house standing in the mark's stride. Anyone else can pause it.

## Consequences

- The house's body now exists three times: in the SVG, in `HouseOutline.swift` and in `site/public/index.html`. The stride exists twice, in Swift and in `site/public/house.js`. Nothing keeps them in step, so a change to the mark or to Push won't reach the page by itself.
- Deploying needs a Cloudflare API token in the repository's secrets.
- The settings that send `http://` to `https://` and `www` to the bare domain are in Cloudflare's dashboard, because a Worker with no script can't redirect by hostname.
- Cloudflare adds its Web Analytics script to the page in browsers. We want those numbers, so the Content Security Policy allows that script and lets it report to `/cdn-cgi/rum` on the site itself. It's the only thing the page loads from anywhere else.
- Cloudflare won't make a preview for a Worker that doesn't exist yet, so the first deploy has to come from `main`.
- There's no way to sign up to hear when the app ships, because that needs a service behind it. A second page would be the time to look at a site generator again, and it can deploy to the same place.
