# Sharer landing page

Pure static HTML/CSS. No build step, no JS dependencies, no framework.

## Local preview

```sh
python -m http.server -d landing 8000
# then open http://localhost:8000
```

Or just double-click `landing/index.html` — it works from `file://` too,
the only quirk is that some browsers block reading sibling files there.

## Editing

- `index.html` — content
- `styles.css` — single stylesheet
- `assets/logo.svg` — gradient triangle logo (three nodes for the P2P mesh)

The download URLs point at GitHub Releases:
`https://github.com/LeninBoccardo/sharer/releases/latest/download/<artifact>`.
That's the GitHub-recommended pattern for "always link to the newest
release" — no tag updates needed when a release ships.

If your repo lives at a different path, search-and-replace
`LeninBoccardo/sharer` in `index.html`.

## Deploy options

The page is static, so anything that serves files works.

### Option 1 — GitHub Pages (zero infra)

Optional workflow shipped at `.github/workflows/landing-deploy.yml`. On
every push to `main` that touches `landing/**`, it publishes the page
to the `gh-pages` branch. To activate:

1. **Settings → Pages → Source: `gh-pages` branch / root**.
2. Push a change touching `landing/`.
3. The page lives at `https://<user>.github.io/sharer/`.

If you want a custom domain, drop a `landing/CNAME` file with the
hostname and configure DNS — the workflow includes it in the deploy.

### Option 2 — Cloudflare Pages

1. Connect the repo at `dash.cloudflare.com/?to=/:account/pages`.
2. Build settings: framework = "None", build command = empty,
   output directory = `landing`.
3. Push to `main`. Cloudflare deploys to a `*.pages.dev` URL
   automatically.

### Option 3 — Netlify drop

1. `netlify deploy --dir=landing --prod` from the repo root.
2. Or drag the `landing/` folder onto `app.netlify.com/drop`.

### Option 4 — Any static host

The folder is fully self-contained. Upload its contents to the
document root of any HTTP server. There's nothing to configure.

## What's NOT here

- No analytics. No tracking pixels. No third-party scripts.
- No favicon download script — the SVG logo doubles as the favicon.
- No CMS / no Markdown — copy lives in `index.html` directly. Three
  paragraphs. Edit when you ship something interesting.
