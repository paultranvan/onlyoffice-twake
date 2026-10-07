#!/usr/bin/env bash
# Build a multi-arch Scribe-patched OnlyOffice image.
#
# Assembles the overlay context — the patched sdkjs word bundle (sdk-all.js) plus
# the Twake Scribe plugin of Twake Drive, built at a pinned git ref — then hands
# it to ../dist/push-multiarch.sh, which builds amd64+arm64 and pushes a single
# multi-arch tag (resilient to harbor.linagora.com's upload resets). The patch is
# version-locked to OnlyOffice build 9.4.0-129.
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
# Overridable via env: TWAKE_DRIVE_REF/TWAKE_DRIVE_REPO (plugin git ref/repo),
# SDKJS_REF/SDKJS_REPO (patched sdkjs source tag/repo), FORMS_REF/FORMS_REPO
# (sdkjs-forms addon), EXPECT_OO_VERSION.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:?Set IMAGE, e.g. harbor.example.com/twake-workplace/onlyoffice:9.4.0.1-scribe-2026-07-22.3}"
BASE_IMAGE="${BASE_IMAGE:?Set BASE_IMAGE, e.g. onlyoffice/documentserver:9.4.0.1}"

# The Twake Scribe plugin lives in Twake Drive (plugins/onlyoffice-scribe), which
# builds it with its Markdown reader. A commit keeps a release reproducible; a
# branch or a tag works too, for a test image.
TWAKE_DRIVE_REPO="${TWAKE_DRIVE_REPO:-https://github.com/linagora/twake-drive.git}"
TWAKE_DRIVE_REF="${TWAKE_DRIVE_REF:-cf4a3e18dc53d0eb1fe234fef718f403ff700790}"
TWAKE_SCRIBE_GUID='asc.{E4B4F030-94E5-48BE-A962-A6E87CB6262B}'
# Patched sdkjs source. sdk-all.js is compiled from it (via scribe/sdkjs.Dockerfile.build),
# not fetched prebuilt. Any compatible sdkjs source tree works, so no Dockerfile is
# required in the source repo.
SDKJS_REPO="${SDKJS_REPO:-https://github.com/Benibur/sdkjs.git}"
SDKJS_REF="${SDKJS_REF:-scribe-sdkjs-2026-07-21.1}"   # sdkjs source tag (a branch works too)
# sdkjs-forms addon, consumed by sdkjs.Dockerfile.build. Overridable here so it can
# follow the OnlyOffice build without editing the Dockerfile.
FORMS_REPO="${FORMS_REPO:-https://github.com/ONLYOFFICE/sdkjs-forms.git}"
FORMS_REF="${FORMS_REF:-v9.4.0.129}"
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
  || { echo "clone of $SDKJS_REPO#$SDKJS_REF failed — is the ref pushed?" >&2; exit 1; }
SDKJS_TAG="scribe-sdkjs-build:$(printf '%s' "$SDKJS_REF" | tr -c 'A-Za-z0-9._-' '-')"
docker build -f "$HERE/sdkjs.Dockerfile.build" -t "$SDKJS_TAG" \
  --build-arg "FORMS_REPO=$FORMS_REPO" --build-arg "FORMS_REF=$FORMS_REF" "$WORK/sdkjs"
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
echo "sdk-all.js OK ($(wc -c <"$CTX/sdk-all.js") bytes; patches + forms present, AscOForm=${forms_n}, forms=${FORMS_REF})"
# Printed so a build can be compared against a reference bundle (the build is
# reproducible: same SDKJS_REF + FORMS_REF -> same bytes).
echo "sdk-all.js sha256 $(sha256sum "$CTX/sdk-all.js" | cut -d' ' -f1)"

# 2. Twake Scribe plugin at the pinned ref -> $CTX/twake-scribe. Twake Drive builds
#    it with plugins/onlyoffice-scribe/build.mjs, which adds the Markdown reader it
#    imports (marked): only marked is installed, at the version Twake Drive asks
#    for, not the dependencies of the whole app. Node runs in Docker, as the sdkjs
#    build does. The Document Server serves its plugins under a path that changes
#    when it starts, so a new image needs no cache-bust stamp.
git init -q "$WORK/drive"
git -C "$WORK/drive" remote add origin "$TWAKE_DRIVE_REPO"
git -C "$WORK/drive" sparse-checkout set plugins/onlyoffice-scribe
git -C "$WORK/drive" fetch -q --depth 1 --filter=blob:none origin "$TWAKE_DRIVE_REF" \
  || { echo "fetch of $TWAKE_DRIVE_REPO#$TWAKE_DRIVE_REF failed — is the ref pushed?" >&2; exit 1; }
git -C "$WORK/drive" checkout -q FETCH_HEAD
DRIVE_COMMIT="$(git -C "$WORK/drive" rev-parse --short=12 HEAD)"
docker run --rm -v "$WORK/drive:/src" -w /src node:24-slim sh -euc '
  npm install --silent --no-audit --no-fund --prefix /tmp/marked \
    "marked@$(node -p "require(\"./package.json\").devDependencies.marked")"
  ln -s /tmp/marked/node_modules node_modules
  node plugins/onlyoffice-scribe/build.mjs
  rm node_modules
  chown -R "$(stat -c %u:%g /src)" plugins/onlyoffice-scribe/build'
cp -a "$WORK/drive/plugins/onlyoffice-scribe/build" "$CTX/twake-scribe"
grep -qF "$TWAKE_SCRIBE_GUID" "$CTX/twake-scribe/config.json" \
  || { echo "twake-scribe/config.json is not the Twake Scribe plugin ($TWAKE_SCRIBE_GUID)" >&2; exit 1; }
[ -s "$CTX/twake-scribe/vendor/marked.esm.js" ] \
  || { echo "twake-scribe is missing its Markdown reader (vendor/marked.esm.js)" >&2; exit 1; }
echo "Twake Scribe plugin $TWAKE_DRIVE_REF ($DRIVE_COMMIT)"

# 4. Dockerfile + hand off to the shared multi-arch build/push engine.
cp "$HERE/Dockerfile" "$CTX/Dockerfile"
IMAGE="$IMAGE" CONTEXT="$CTX" BASE_IMAGE="$BASE_IMAGE" EXPECT_OO_VERSION="$EXPECT_OO_VERSION" \
  "$HERE/../dist/push-multiarch.sh"
