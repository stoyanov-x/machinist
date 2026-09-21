# syntax=docker/dockerfile:1

# Image for the optional Caddy proxy in docker-compose.bridge.yml.
#
# The Caddyfile and the entrypoint are baked in rather than bind mounted. Coolify
# runs the Compose file from a deployment directory where a relative bind source
# may not exist, and Docker then creates a *directory* at the missing path, which
# fails as:
#
#   cannot create subdirectories in ".../etc/caddy/Caddyfile": not a directory
#
# An image has no such dependency and behaves identically locally and on the
# server. Coolify also injects ARG declarations for a service that builds, which
# this image simply does not use.

FROM caddy:2-alpine

COPY deploy/container/Caddyfile /etc/caddy/Caddyfile
COPY deploy/container/proxy-entrypoint.sh /etc/machinist-proxy/entrypoint.sh

ENTRYPOINT ["/bin/sh", "/etc/machinist-proxy/entrypoint.sh"]
