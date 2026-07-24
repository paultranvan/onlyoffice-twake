# Multi-arch build & push

`push-multiarch.sh` builds an OnlyOffice image for `linux/amd64` + `linux/arm64`
and publishes it as one multi-arch tag. It builds the analytics-free overlay by
default, and doubles as the shared push engine for the [Scribe build](../scribe/).

## Why chunked uploads

`harbor.linagora.com` sits behind a proxy that times out (`504 Gateway Timeout`,
then `499`) on a single large blob upload. The base image has a ~1GB layer, and
pushing it in one request never finishes from a CI or otherwise slow network, so a
one-shot `buildx --push` (or plain `docker push`) fails partway through and retrying
just restarts the same doomed upload.

The script instead builds a multi-arch OCI layout and pushes it with
[`regctl`](https://github.com/regclient/regclient), configured to upload each blob
in small `PATCH` chunks (16MB by default). Every chunk is a short request well under
the proxy timeout, and regctl resumes from the last offset on failure. Because
regctl pushes the multi-arch index directly, there are no per-arch helper tags to
create or clean up.

`regctl` is downloaded (a pinned static binary) if it is not already on `PATH`, and
it reuses the `docker login` credentials, so no extra setup is needed.

## Usage

```bash
docker login harbor.linagora.com

# analytics-free overlay (context = dist/, needs dist/apps from ../build-webapps.sh)
IMAGE=harbor.linagora.com/twake-workplace/onlyoffice-noanalytics:latest \
  dist/push-multiarch.sh
```

Environment:

| var | purpose |
|-----|---------|
| `IMAGE` | target `repo:tag` (required) |
| `CONTEXT` | build context dir (default `dist/`) |
| `BASE_IMAGE` | passed as `--build-arg BASE_IMAGE` when the Dockerfile takes one |
| `EXPECT_OO_VERSION` | passed as `--build-arg EXPECT_OO_VERSION` (version guard) |
| `PLATFORMS` | platforms to build (default `linux/amd64,linux/arm64`) |
| `BLOB_CHUNK` | chunk size in bytes (default `16000000`) |

## HTTP access logs & observability

By default the DS image sets `access_log off`, and even when enabled it writes to
`/var/log/nginx/` — a path the entrypoint does **not** `tail`, so nginx access logs
never reach the container stdout (nor Loki/Grafana in k8s). The node service logs
already reach stdout (log4js `console` appender → supervisord → the entrypoint's
`tail -F` of `/var/log/onlyoffice/documentserver/*.log`).

This overlay closes the gap:

- bakes `NGINX_ACCESS_LOG=true`, which makes the entrypoint write the access log
  under `/var/log/onlyoffice/documentserver/` (the tailed dir → stdout);
- installs a `ds_timing` log format (`dist/ds-logformat.conf`) carrying
  `rt=$request_time` and `urt=$upstream_response_time`, so latency can be split
  between the client/network (`rt` high, `urt` low/`-`) and the node backend
  (`urt` high).

Sample line:

```
10.0.0.1 docs.example.com 200 "GET /web-apps/apps/api/documents/api.js HTTP/1.1" rt=0.003 urt=- cache=- len=65363 ref="-" ua="Mozilla/5.0 ..."
```

Notes:
- The `tail` (and thus stdout access logs) starts only after font/theme generation
  at boot — expect a ~1–2 min delay on a cold start before HTTP lines appear.
- Access logs contain client IPs and full request paths — keep that in mind for
  retention/PII. Set `NGINX_ACCESS_LOG=false` at runtime to turn them back off
  (the `ds_timing` format stays defined but unused).

## arm64 emulation

Now **required** for the multi-arch build: the access-log overlay adds a per-arch
`RUN` (nginx/entrypoint patch), so it is no longer COPY-only. Same requirement as
the Scribe version guard:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Single-arch / local only

```bash
../build-webapps.sh
docker build -t onlyoffice-noanalytics:9.4.0-noanalytics .
docker run -d -p 80:80 onlyoffice-noanalytics:9.4.0-noanalytics   # http://localhost/
```
