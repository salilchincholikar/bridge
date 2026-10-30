# Website maintenance

The landing page is a dependency-free static site hosted at https://salilchincholikar.github.io/bridge/.

## Build locally

Run `make site`. Open `_site/index.html` in a browser or serve `_site` with a local HTTP server. Generated output is ignored by Git.

Edit `site/index.html`, `site/styles.css` and `site/script.js`. The builder reads the version from `Resources/Info.plist`, copies the app icon and uses `docs/images/overview.png` for the product screenshot. Use fictional demo data for public captures.

## Deployment

The GitHub Pages workflow builds and deploys `_site` when relevant files change on `main`, or when manually dispatched. Repository Settings → Pages → Build and deployment uses **GitHub Actions**, enabled by the repository owner. For a new fork, select this setting before running the deployment workflow.

Only generated site files are uploaded. App bundles, fixtures, credentials and the rest of the repository are outside the Pages artifact. Asset paths are relative so the site works under the `/bridge/` project path.

There is no published installer yet; the page directs visitors to source builds. Update that copy when a signed release exists. No analytics, external fonts or client libraries are loaded.
