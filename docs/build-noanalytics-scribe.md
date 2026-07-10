# Build the “analytics-free + Scribe” image

How the OnlyOffice DocumentServer image that is **both** analytics-free **and**
carries the Scribe addon gets published, and how to reproduce it locally when you
need to debug it.

The variant is two images stacked: the analytics-free image (the base), then the
Scribe overlay layered on top of it. The sdkjs / forms / plugin sources are pinned
as defaults in `scribe/build-scribe.sh`, so nothing is passed by hand.

| Result image | Base | Analytics | Scribe |
|--------------|------|-----------|--------|
| `onlyoffice:<version>-scribe` | analytics-free | removed | yes |

## Publishing (this is the normal path)

CI builds and pushes both images. Nobody needs a Harbor account, and no image is
ever built on a laptop for production.

**Cut a release.** Tagging publishes the base, then the overlay on top of it, and
only creates the GitHub release once both are on Harbor:

```bash
git tag v9.4.0.1 && git push origin v9.4.0.1
```

| Tag pushed | Images published |
|------------|------------------|
| `v9.4.0.1` | `onlyoffice-noanalytics:9.4.0.1`, then `onlyoffice:9.4.0.1-scribe` |

**Or rebuild just the overlay.** The *Publish Scribe overlay to Harbor* workflow is
dispatchable from the Actions tab. Give it the tag to publish (a date-stamped label
such as `9.4.0-noanalytics-scribe-2026-07-09.1`) and the base tag to layer onto
(defaults to `latest`, which `main` republishes on every merge). Use this when the
overlay sources have moved but the base has not.

> **Reproducibility caveat.** `SDKJS_REF` defaults to a *branch*
> (`integration/scribe-oo-9.4.0.129`), not a tag, so two builds of the same git tag
> can produce different images. Until it is pinned to a tag or a commit, the
> date-stamped dispatch label is what actually distinguishes one overlay build from
> another.

## Building locally (debugging only)

Only when you need to inspect the build itself. The result is not what gets
deployed; publish via CI.

```bash
git clone https://github.com/linagora/onlyoffice-twake.git && cd onlyoffice-twake

# arm64 emulation: the overlay's version guard is a RUN step, once per architecture
docker run --privileged --rm tonistiigi/binfmt --install arm64

# 1. Rebuild the 5 editors with Google Analytics removed -> dist/apps/
#    (self-checks trackEvent=0; fails otherwise). Must run natively, not under QEMU.
./build-webapps.sh

# 2. Layer Scribe onto a base. Any published analytics-free tag works as BASE_IMAGE;
#    the overlay build pulls it from the registry, not from the local image store.
IMAGE=onlyoffice:local-scribe \
BASE_IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:latest \
  scribe/build-scribe.sh
```

`scribe/build-scribe.sh` compiles `sdk-all.js` (Scribe patch + forms addon) from
`Benibur/sdkjs` and adds the Scribe plugin. It **fails** if the patch, the forms API
(`AscOForm`), or the base build version are not as expected.

## Verify an image

```bash
docker run --rm -p 8091:80 -e JWT_ENABLED=false <image>

# in another terminal:
curl -s localhost:8091/healthcheck                                    # true
SDK=$(curl -s localhost:8091/sdkjs/word/sdk-all.js)
printf '%s' "$SDK" | grep -c GetInlineDrawings                        # 4   (Scribe patch)
printf '%s' "$SDK" | grep -c AscOForm                                 # 69  (forms addon)
for ED in documenteditor spreadsheeteditor presentationeditor pdfeditor visioeditor; do
  echo -n "$ED trackEvent="; curl -s "localhost:8091/web-apps/apps/$ED/main/code.js" | grep -c trackEvent
done                                                                  # all 0 (analytics removed)
curl -s -o /dev/null -w "plugin %{http_code}\n" localhost:8091/sdkjs-plugins/scribe/index.html  # 200
```

All good when: `healthcheck=true`, `GetInlineDrawings=4`, `AscOForm=69`,
`trackEvent=0` everywhere, plugin `200`.

## See also

- [`../README.md`](../README.md) — the image family and overlay overview
- [`../scribe/README.md`](../scribe/README.md) — Scribe overlay internals, env vars, forms addon gotcha
- [`../dist/README.md`](../dist/README.md) — the multi-arch chunked push engine
