# Caddy Direct-Request STDOUT Design

## Goal

When PatataTube is running through `./serve`, show requests that Caddy serves directly instead of FastAPI. Give these entries their own color and avoid duplicate output for requests that Caddy proxies to Python.

## Architecture

The Patata Caddy routes will explicitly annotate access-log events only after a request has selected a direct file-serving path. Static assets and root icons are always annotated before `file_server`. HLS and MP4 routes are annotated only when their on-disk matcher succeeds; their FastAPI fallback remains unmarked.

Caddy will continue writing its complete JSON access log to `log/caddy_access.log`. The annotation adds a stable machine-readable field without changing or splitting the existing log destination.

`./serve` will start a follower at the end of that file, select only newly appended entries carrying the direct-response annotation, format them as concise access lines, and send them to the terminal through the existing color-label mechanism. Both development and production modes will use a magenta `caddy` label. Existing `dev`, `web`, `access`, and `app` streams retain their current colors and behavior.

## Output

Each direct Caddy response will produce one line containing:

- HTTP method
- original request path, with the query string omitted
- response status
- response byte count
- request duration

The full JSON entry remains available in `log/caddy_access.log`. Existing log redaction remains Caddy's responsibility; the concise terminal formatter will not print request headers, query parameters, or credentials.

## Process Lifecycle and Failure Handling

The follower will begin at end-of-file so historical requests are not replayed when `./serve` starts. It will tolerate the access log being created after startup and follow the filename across Caddy log rotation.

The follower is auxiliary: a missing or temporarily unavailable log must not prevent FastAPI from starting. `./serve` will own the follower and stop it when the server exits or receives a termination signal, so repeated development restarts do not accumulate background processes.

## Verification

Automated shell-level tests will use a temporary access log and fake server process to verify:

- marked Caddy entries appear once with the `caddy` label;
- unmarked proxied entries do not appear;
- pre-existing entries are not replayed;
- relevant JSON fields are formatted correctly;
- the follower exits with `./serve`.

Caddy configuration validation will confirm that all direct file-server paths add the annotation and every reverse-proxy fallback remains unmarked. A manual smoke test will request one static asset and one FastAPI endpoint through port 3050 and confirm that only the asset gets the new terminal line.

## Scope

This change is limited to the Patata site in `../server/Caddyfile`, the local `./serve` launcher, and focused tests. It does not change request routing, authentication, cache headers, Caddy's complete access-log retention, or other sites in the shared Caddyfile.
