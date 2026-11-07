# Site

The landing page at [roga.sh](https://roga.sh). It's static files in `public/` with no build step, served by Cloudflare Workers ([decision 22](../docs/decisions/0022-host-the-landing-page-on-cloudflare-workers.md)).

## Running it

This serves the page the way Cloudflare will, with the headers in `public/_headers` and the 404 page:

```bash
npx --yes wrangler@4.157.0 dev --cwd site
```

## Deploying

[`site.yml`](../.github/workflows/site.yml) runs whenever something in `site/` changes. Merging to `main` deploys to roga.sh, and a pull request gets a comment with the address of its preview.

## Analytics

Cloudflare adds its Web Analytics script to the page when a browser asks for it, so the live page isn't quite the file in `public/`, and `curl` gets it without the script. The policy in `public/_headers` allows that script and lets it report to the site itself. Tightening the policy stops the numbers without any visible sign on the page, apart from an error in the browser console.

## Setting it up

This only needs doing once.

1. In the [Cloudflare dashboard](https://dash.cloudflare.com/profile/api-tokens), create an API token from the **Edit Cloudflare Workers** template, limited to your account and the `roga.sh` zone.
2. Add the token and your account ID to the repository. Each command asks for its value, so it stays out of your shell history:

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN --repo tmarkovski/roga
   ```

   ```bash
   gh secret set CLOUDFLARE_ACCOUNT_ID --repo tmarkovski/roga
   ```

3. Merge the site to `main`. The first deploy creates the Worker and attaches `roga.sh` to it. Cloudflare won't make a preview for a Worker that doesn't exist yet, so the **Preview** job on that first pull request fails. Later pull requests get their previews.
4. Previews live on `workers.dev`, so the account needs a subdomain there. The dashboard offers one the first time you open **Workers & Pages**.

Two settings on the `roga.sh` zone can't be set from this repository, and both are in the dashboard:

- **Send `http://` to `https://`:** turn on **SSL/TLS > Edge Certificates > Always Use HTTPS**.
- **Send `www.roga.sh` to `roga.sh`:** add a proxied `AAAA` record for `www` pointing at `100::`, then use the **Redirect from WWW to root** template under **Rules**.

## The images

`favicon.svg` is the mark from [`docs/design/branding`](../docs/design/branding), and the PNGs were rendered from the same artwork. `index.html` holds its own copies of the house's body and the wordmark, and `house.js` holds the walk from `RogaKit/Sources/RogaUI/House/`. Nothing keeps these in step automatically.
