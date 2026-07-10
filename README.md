# OnlyOffice DocumentServer images for Twake

Custom multi-arch builds of **OnlyOffice DocumentServer 9.4.0** (build `9.4.0-129`),
published to Harbor under the `twake-workplace` project. Two independent overlays on
the official `onlyoffice/documentserver` image, composed into the shipped images:

- **analytics-free**: Google Analytics tracking removed from the editors.
- **Scribe**: the Scribe editor addon (patched `sdkjs` + plugin).

| Image (tag) | Base | Analytics | Scribe |
|-------------|------|-----------|--------|
| `onlyoffice-noanalytics:9.4.0-noanalytics` | official 9.4.0 | removed | no |
| `onlyoffice:9.4.0-noanalytics-scribe-<build>` | analytics-free | removed | yes |
| `onlyoffice:9.4.0.1-scribe-<build>` | official 9.4.0.1 | stock | yes |

Every image is `linux/amd64` + `linux/arm64`. The `9.4.0` and `9.4.0.1` tags are the
same OnlyOffice build (`9.4.0-129`).

## How it works

The official image installs a prebuilt `.deb` with the editors deployed under
`/var/www/onlyoffice/documentserver/`. Rather than a multi-hour source build, each
customization is a thin **overlay** layered onto that image:

- **analytics-free** (`dist/`): the 5 main desktop editors
  (`document/spreadsheet/presentation/pdf/visio`) rebuilt from `web-apps` `9.4.0`
  (base commit `1993a6d8`) with `analytics-removal.patch` applied (upstream commit
  [`48dcc5c`](https://github.com/ONLYOFFICE/web-apps/commit/48dcc5c22c8463a39c5368fcb3c55da793a915a9),
  "removed Analytic module sources"), replacing the stock `apps/`. That commit
  landed three days after the 9.4.0 release, so it is not in the stock image. The
  overlay is pure JS/HTML, so it is architecture-independent (clean multi-arch, no
  emulation).
- **Scribe** (`scribe/`): a patched `sdk-all.js` plus the `sdkjs-plugins/scribe`
  addon, layered onto either the analytics-free image or stock 9.4.0.1. The patch
  and plugin are version-locked to build `9.4.0-129` (a build guard enforces it).

### Analytics scope

The 5 main desktop editors, where the GA module (`UA-12442749-13`) and
`trackEvent()` calls actually ran, are fully cleaned (0 occurrences in the served
bundles). The mobile and embed editors keep stock 9.4.0 behaviour; their analytics
path was already inert (the embed `Common.Analytics` object is never defined).

## Publishing

CI holds the Harbor credentials and pushes every image. A release tag publishes the
analytics-free base and then the Scribe overlay on top of it:

```bash
git tag v9.4.0.1 && git push origin v9.4.0.1   # -> onlyoffice-noanalytics:9.4.0.1
                                               # -> onlyoffice:9.4.0.1-scribe
```

Merging to `main` republishes `onlyoffice-noanalytics:latest`. The Scribe overlay can
also be rebuilt on its own from the Actions tab.

## Building locally

To debug a build. These produce local images; publishing goes through CI.

```bash
./build-webapps.sh                       # rebuild GA-free editor bundles -> dist/apps/

docker run --privileged --rm tonistiigi/binfmt --install arm64   # arm64 emulation, once

IMAGE=onlyoffice:local-scribe \
BASE_IMAGE=onlyoffice/documentserver:9.4.0.1 \
  scribe/build-scribe.sh
```

See **[`scribe/README.md`](scribe/README.md)** for both variants and options, and
**[`dist/README.md`](dist/README.md)** for the multi-arch push engine, including how
it survives Harbor resetting large blob uploads (build per arch, push with
retry-until-converge, then stitch into one manifest). For a full from-scratch
runbook of the analytics-free + Scribe variant, see
**[`docs/build-noanalytics-scribe.md`](docs/build-noanalytics-scribe.md)**.

### Local single-arch

```bash
./build-webapps.sh
docker build -t onlyoffice-noanalytics:9.4.0-noanalytics dist/
docker run -d -p 80:80 onlyoffice-noanalytics:9.4.0-noanalytics   # http://localhost/
```

## Continuous integration

GitHub Actions build and publish the **analytics-free** image to Harbor. The Scribe
variants are built manually via `scribe/build-scribe.sh`.

| Trigger | Result |
|---------|--------|
| Pull request | Builds the image to validate it. Does not push. |
| Push to `main` | Publishes `<project>/onlyoffice-noanalytics:latest`. |
| Push a `vX.Y.Z` tag | Publishes a versioned image and creates a GitHub release. |

Set four repository secrets before the first publish: `HARBOR_REGISTRY`,
`HARBOR_USER`, `HARBOR_PASSWORD`, `HARBOR_PROJECT`. The pushed repository is
`$HARBOR_REGISTRY/$HARBOR_PROJECT/onlyoffice-noanalytics`.

### Releasing a new version

The image tag is the git tag with the leading `v` stripped, so `v9.4.0-noanalytics`
publishes `.../onlyoffice-noanalytics:9.4.0-noanalytics`.

```bash
git checkout main && git pull
git tag v9.4.0-noanalytics
git push origin v9.4.0-noanalytics
```

The tag must match `v[0-9]+.[0-9]+.[0-9]+*`; pushing it builds the multi-arch image,
pushes the versioned tag to Harbor, and opens a GitHub release with generated notes.

## Verification

Checked on served builds:

- `healthcheck` returns `true`; the Document Editor boots in a browser with no
  console errors.
- Analytics-free editors: `trackEvent` / `component.Analytics` / `UA-12442749` = **0**
  in all 5 served `code.js` bundles (stock base had doc=8, sheet=33, slide=35, pdf=25).
- Scribe images: `sdk-all.js` carries the patch (`GetInlineDrawings`), the plugin is
  served, and the editor analytics match the base (0 on the analytics-free base,
  stock on 9.4.0.1).

## Repo layout

| Path | Purpose |
|------|---------|
| `analytics-removal.patch` | GA removal, applies onto web-apps `9.4.0` base `1993a6d8` |
| `build-webapps.sh` | Clone + patch + grunt build -> `dist/apps/` |
| `dist/` | Analytics-free overlay (`Dockerfile`) + multi-arch push engine (`push-multiarch.sh`); see `dist/README.md` |
| `scribe/` | Scribe overlay (`Dockerfile`, `build-scribe.sh`); see `scribe/README.md` |
| `.github/workflows/` | CI: build on PR, publish `latest` on `main`, publish a version on a `v*` tag |

`web-apps/`, `dist/apps/`, and `node_modules/` are generated and git-ignored.
