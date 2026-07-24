# OnlyOffice DocumentServer 9.4.0 — analytics removed
#
# Base: official onlyoffice/documentserver:9.4.0 (latest stable, multi-arch).
# Overlay: the 5 main editors (document/spreadsheet/presentation/pdf/visio),
# rebuilt from web-apps `release/v9.4.0` with commit 48dcc5c
# ("[all] removed Analytic module sources") applied. This strips the Google
# Analytics module and all trackEvent() calls from the editor `code.js` bundles.
#
# Architecture-independent: the overlay is pure JS/HTML/CSS, so the same files
# are layered onto each platform's base image with no per-arch rebuild.
FROM onlyoffice/documentserver:9.4.0

COPY --chown=ds:ds apps/ /var/www/onlyoffice/documentserver/web-apps/apps/

# --- HTTP access logging with timings, surfaced on the container stdout -------
# By default the DS image sets `access_log off` and, even when enabled, writes to
# /var/log/nginx/ which the entrypoint does NOT tail — so nginx access logs never
# reach the container stdout (and therefore never reach Loki/Grafana in k8s).
#
# NGINX_ACCESS_LOG=true makes the entrypoint write the access log under
# /var/log/onlyoffice/documentserver/, which it `tail -F`s to stdout. We bake it
# on (still overridable at runtime) and upgrade the format to `ds_timing`
# ($request_time + $upstream_response_time) so slowness can be attributed to the
# client/network vs the node backend. Node service logs already reach stdout via
# the same tail (log4js -> console -> supervisord -> tail).
#
# NOTE: this RUN makes the overlay no longer COPY-only, so the multi-arch build
# now needs arm64 emulation (`docker run --privileged --rm tonistiigi/binfmt
# --install arm64`), like the Scribe overlay. See dist/README.md.
COPY ds-logformat.conf /etc/nginx/ds-logformat.conf
RUN set -eux; \
    # 1. load the log_format at the top of http{}, before any access_log uses it
    grep -q '^http {' /etc/nginx/nginx.conf; \
    sed -i 's|^http {|http {\ninclude /etc/nginx/ds-logformat.conf;|' /etc/nginx/nginx.conf; \
    grep -q 'include /etc/nginx/ds-logformat.conf;' /etc/nginx/nginx.conf; \
    # 2. make the entrypoint's NGINX_ACCESS_LOG rewrite use the ds_timing format
    grep -qF "/nginx.access.log;|'" /app/ds/run-document-server.sh; \
    sed -i "s#/nginx.access.log;|'#/nginx.access.log ds_timing;|'#" /app/ds/run-document-server.sh; \
    grep -qF "/nginx.access.log ds_timing;|'" /app/ds/run-document-server.sh
# `nginx -t` is intentionally NOT run at build time: the pristine config
# references a `cache_tag` variable that only exists once the entrypoint has run,
# so it fails pre-boot. The config is validated at runtime by the entrypoint.
ENV NGINX_ACCESS_LOG=true
