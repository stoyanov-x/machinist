#!/bin/sh
#
# Entrypoint for the optional Caddy proxy that publishes the Machinist UI.
#
# This lives in a script rather than an inline Compose command for two reasons:
# Compose would otherwise interpolate every "$" used below (each would need
# doubling, which is easy to get wrong), and the failure messages stay readable.
#
# The container refuses to start when MACHINIST_EXPOSED is true and credentials
# or the worker token are missing, so an unauthenticated administrative UI
# cannot reach the internet by accident.

set -eu

if [ "${MACHINIST_EXPOSED:-true}" != "true" ]; then
	echo "machinist-proxy: MACHINIST_EXPOSED is not true, so no public listener is started." >&2
	echo "machinist-proxy: reach the UI with: ssh -N -L 7444:127.0.0.1:7444 <server>" >&2
	exec sleep infinity
fi

missing=""
if [ -z "${MACHINIST_AUTH_USER:-}" ]; then
	missing="$missing MACHINIST_AUTH_USER"
fi
if [ -z "${MACHINIST_AUTH_PASSWORD_HASH:-}" ]; then
	missing="$missing MACHINIST_AUTH_PASSWORD_HASH"
fi
if [ -z "${MACHINIST_TOKEN:-}" ]; then
	missing="$missing MACHINIST_TOKEN"
fi

if [ -n "$missing" ]; then
	echo "machinist-proxy: refusing to start. MACHINIST_EXPOSED=true would publish an admin UI that has no authentication of its own, so these are required:" >&2
	echo "machinist-proxy:  $missing" >&2
	echo "machinist-proxy: see deploy/container/README.md, section 'Exposing the UI'." >&2
	exit 1
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
