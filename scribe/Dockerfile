# Scribe-patched OnlyOffice Document Server overlay.
#
# Layers two artifacts onto a base OnlyOffice image (build 9.4.0-129):
#   • a patched sdkjs word bundle (sdk-all.js with ApiRun.GetInlineDrawings)
#   • the Twake Scribe plugin of Twake Drive (sdkjs-plugins/twake-scribe)
#
# The build context (sdk-all.js + twake-scribe/) is assembled by build-scribe.sh.
# BASE_IMAGE selects the foundation: point it at stock
# onlyoffice/documentserver:9.4.0.1 or at the analytics-free image from this repo.
#
# Adapted from Benibur/cozy-drive deploy/integration/image/Dockerfile.

ARG BASE_IMAGE=onlyoffice/documentserver:9.4.0.1
FROM ${BASE_IMAGE}

# Fail early if the base is not the exact OO build the compiled patch targets —
# a version-locked sdk-all.js on a different build breaks the editor.
ARG EXPECT_OO_VERSION=9.4.0-129
RUN dpkg-query -W -f='${Version}\n' onlyoffice-documentserver | grep -qx "${EXPECT_OO_VERSION}" \
    || (echo "ERROR: base OnlyOffice is not ${EXPECT_OO_VERSION} — the compiled sdkjs patch is version-locked and would break the editor." >&2; exit 1)

# Patched sdkjs word bundle (builder API + GetInlineDrawings). On 9.4 apiBuilder.js
# lives only in sdk-all.js, so this single file carries the patch.
COPY sdk-all.js /var/www/onlyoffice/documentserver/sdkjs/word/sdk-all.js

# Twake Scribe plugin, built from Twake Drive by build-scribe.sh. The Document
# Server finds it in the folder alone, with no registration step.
COPY twake-scribe/ /var/www/onlyoffice/documentserver/sdkjs-plugins/twake-scribe/
