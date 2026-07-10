#!/usr/bin/env bash
# Build a multi-arch Scribe-patched OnlyOffice image.
#
# Assembles the overlay context — the patched sdkjs word bundle (sdk-all.js) plus
# the Scribe plugin at a pinned git ref, with the plugin's index.html cache-bust
# stamped — then hands it to ../dist/push-multiarch.sh, which builds amd64+arm64
# and pushes a single multi-arch tag (resilient to harbor.linagora.com's upload
# resets). The plugin and patch are version-locked to OnlyOffice build 9.4.0-129.
#
# The BASE_IMAGE picks the foundation:
#   • onlyoffice/documentserver:9.4.0.1                 -> stock + Scribe
#   • <registry>/twake-workplace/onlyoffice:9.4.0-noanalytics -> analytics-free + Scribe
#
# Prerequisites: docker login <registry>; arm64 emulation for the version guard:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Usage:
#   IMAGE=<repo:tag> BASE_IMAGE=<oo-image> ./scribe/build-scribe.sh
#
# Overridable via env: SCRIBE_REF/SCRIBE_REPO (plugin git tag/repo),
# SDKJS_REF/SDKJS_REPO (patched sdkjs source branch/repo), EXPECT_OO_VERSION.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/twake-workplace/onlyoffice:9.4.0.1-scribe-2026-07-09.1}"
BASE_IMAGE="${BASE_IMAGE:?Set BASE_IMAGE, e.g. onlyoffice/documentserver:9.4.0.1}"

SCRIBE_REPO="${SCRIBE_REPO:-https://github.com/Benibur/cozy-drive.git}"
SCRIBE_REF="${SCRIBE_REF:-scribe-2026-07-09.1}"       # plugin git tag (== SCRIBE_BUILD)
# Patched sdkjs source. sdk-all.js is compiled from it (via scribe/sdkjs.Dockerfile.build),
# not fetched prebuilt. Any compatible sdkjs source tree works, so no Dockerfile is
# required in the source repo.
SDKJS_REPO="${SDKJS_REPO:-https://github.com/Benibur/sdkjs.git}"
SDKJS_REF="${SDKJS_REF:-integration/scribe-oo-9.4.0.129}"   # sdkjs source branch
export EXPECT_OO_VERSION="${EXPECT_OO_VERSION:-9.4.0-129}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CTX="$WORK/ctx"; mkdir -p "$CTX"

# 1. Patched sdk-all.js — compiled from the sdkjs source branch, not a prebuilt
#    tarball. Clone the ref, build the word bundle in Docker via the vendored
#    scribe/sdkjs.Dockerfile.build (which also merges the sdkjs-forms addon, so the
#    source repo needs no Dockerfile of its own), extract the emitted sdk-all.js,
#    and verify the patched methods AND the forms addon are present before baking.
#    The bundle is plain JS (architecture-independent), so one build feeds both
#    arches downstream.
git clone --depth 1 --branch "$SDKJS_REF" "$SDKJS_REPO" "$WORK/sdkjs" >/dev/null 2>&1 \
  || { echo "clone of $SDKJS_REPO#$SDKJS_REF failed — is the branch pushed?" >&2; exit 1; }
SDKJS_TAG="scribe-sdkjs-build:$(printf '%s' "$SDKJS_REF" | tr -c 'A-Za-z0-9._-' '-')"
docker build -f "$HERE/sdkjs.Dockerfile.build" -t "$SDKJS_TAG" "$WORK/sdkjs"
trap 'rm -rf "$WORK"; [ -n "${cid:-}" ] && docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
cid="$(docker create "$SDKJS_TAG")"
docker cp "$cid:/sdkjs/deploy/sdkjs/word/sdk-all.js" "$CTX/sdk-all.js"
docker rm -v "$cid" >/dev/null
grep -q GetInlineDrawings "$CTX/sdk-all.js"    || { echo "sdk-all.js missing the patch (GetInlineDrawings)" >&2; exit 1; }
grep -q GetSelectionScreenRect "$CTX/sdk-all.js" || { echo "sdk-all.js missing the patch (GetSelectionScreenRect)" >&2; exit 1; }
# The sdkjs-forms addon must be merged in (Word forms API). A silent --addon
# resolution failure leaves AscOForm at 3 instead of ~69, with no build error.
forms_n="$(grep -c AscOForm "$CTX/sdk-all.js" || true)"
[ "${forms_n:-0}" -ge 60 ] || { echo "sdk-all.js missing the sdkjs-forms addon (AscOForm=${forms_n}, expected ~69)" >&2; exit 1; }
echo "sdk-all.js OK ($(wc -c <"$CTX/sdk-all.js") bytes; patches + forms present, AscOForm=${forms_n})"

# 2. Scribe plugin at the pinned ref -> $CTX/scribe (drop stale pre-gzipped assets).
git clone --depth 1 --branch "$SCRIBE_REF" --filter=blob:none --sparse "$SCRIBE_REPO" "$WORK/repo" >/dev/null 2>&1
git -C "$WORK/repo" sparse-checkout set plugins/onlyoffice-scribe >/dev/null 2>&1
cp -a "$WORK/repo/plugins/onlyoffice-scribe" "$CTX/scribe"
find "$CTX/scribe" -name '*.gz' -delete 2>/dev/null || true

# 3. Cache-bust stamp: index.html -> code.js?v=<SCRIBE_BUILD>, so browsers re-fetch
#    on every plugin bump.
BUILD_STR="$(grep -o 'SCRIBE_BUILD *= *"[^"]*"' "$CTX/scribe/scripts/code.js" | sed 's/.*= *"//; s/".*//' | head -1 || true)"
TOKEN="$(printf '%s' "${BUILD_STR%% *}" | tr -c 'A-Za-z0-9._-' '-')"; [ -n "$TOKEN" ] || TOKEN="build"
sed -i -E "s#(src=\"scripts/code\.js)(\?v=[^\"]*)?\"#\1?v=${TOKEN}\"#" "$CTX/scribe/index.html"
echo "Scribe plugin $SCRIBE_REF, cache-bust ?v=${TOKEN}"

# 4. Dockerfile + hand off to the shared multi-arch build/push engine.
cp "$HERE/Dockerfile" "$CTX/Dockerfile"
IMAGE="$IMAGE" CONTEXT="$CTX" BASE_IMAGE="$BASE_IMAGE" EXPECT_OO_VERSION="$EXPECT_OO_VERSION" \
  "$HERE/../dist/push-multiarch.sh"
