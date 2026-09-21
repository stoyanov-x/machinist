# syntax=docker/dockerfile:1

# Container packaging for the upstream Machinist release.
#
# This mirrors scripts/setup-vm.sh -- Ubuntu, the unprivileged `machinist`
# account, GitHub CLI, Codex, Claude Code -- with the two systemd units replaced
# by deploy/container/entrypoint.sh. None of the repository's Go code is
# modified, so this stays a thin packaging layer over upstream.

FROM ubuntu:24.04

# Optional. Leave it unset and the image installs the newest release, which is
# what upstream's install.sh does on its own. Set it to pin, for example
# --build-arg MACHINIST_VERSION=v0.4.0.
ARG MACHINIST_VERSION=
ARG DEBIAN_FRONTEND=noninteractive

# $HOME/.local/bin comes first: the volume-backed Machinist copy that the
# entrypoint seeds will shadow the pinned release at /usr/local/bin, so
# `machinist update` takes effect on the next restart.
ENV MACHINIST_VERSION=${MACHINIST_VERSION} \
    AGENT_HOME=/opt/agent-home \
    PATH=/home/machinist/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gh \
      git \
      jq \
      openssh-client \
      socat \
      tar \
      tini \
 && rm -rf /var/lib/apt/lists/*

# Pin GitHub's published host keys so git-over-SSH works without an interactive
# first-connection prompt. docs/vm-deployment.md asks you to compare the
# fingerprints by hand; this is the same published data over HTTPS.
#
# api.github.com allows only 60 unauthenticated requests per hour per IP and
# answers 403 once exhausted, which was observed on a real host. An empty
# known_hosts would break `git clone` over SSH later, so fall back to ssh-keyscan
# rather than silently writing nothing.
RUN install -d -m 0755 /etc/ssh \
 && { curl -fsSLS -o /tmp/gh-meta.json https://api.github.com/meta \
      && jq -r '.ssh_keys[]' /tmp/gh-meta.json | sed 's|^|github.com |' > /etc/ssh/ssh_known_hosts; } \
    || true \
 && if [ ! -s /etc/ssh/ssh_known_hosts ]; then \
      printf 'warning: api.github.com did not return host keys (rate limited?); falling back to ssh-keyscan\n' >&2; \
      ssh-keyscan -t rsa,ecdsa,ed25519 github.com > /etc/ssh/ssh_known_hosts 2>/dev/null || true; \
    fi \
 && rm -f /tmp/gh-meta.json \
 && test -s /etc/ssh/ssh_known_hosts \
 || { printf 'could not obtain GitHub SSH host keys from the API or ssh-keyscan\n' >&2; exit 1; }

# The unprivileged runtime account, matching the upstream VM deployment.
RUN useradd --create-home --shell /bin/bash machinist

# Codex and Claude Code keep credentials per user, so install their standalone
# distributions as the account that will run them. Both installers write to
# $HOME/.local/bin and $HOME is a volume at runtime, so they are staged here and
# copied into the volume on first boot rather than being shadowed by it.
#
# The whole staging HOME must belong to `machinist`: the installers also create
# their own state directories (for example $HOME/.codex) beside .local/bin.
RUN install -d -o machinist -g machinist "${AGENT_HOME}" \
 && chown -R machinist:machinist "${AGENT_HOME}" \
 && runuser -u machinist -- env HOME="${AGENT_HOME}" \
      bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
 && runuser -u machinist -- env HOME="${AGENT_HOME}" \
      bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
 && test -x "${AGENT_HOME}/.local/bin/codex" \
 && test -x "${AGENT_HOME}/.local/bin/claude"

# Machinist release. The upstream installer verifies the archive against the
# published SHA-256 checksum before installing. This is the fallback copy; the
# entrypoint seeds a writable, volume-backed copy on first boot.
#
# Unset means "newest release", resolved here exactly as install.sh would do it
# itself. That makes the image non-reproducible: the same commit builds a
# different image over time. Pin with --build-arg MACHINIST_VERSION=v0.4.0 when
# that matters.
#
# The newest tag comes from the public release redirect, NOT api.github.com: the
# unauthenticated API allows only 60 requests per hour per IP, and a shared or
# recently recycled cloud IP can already have exhausted that. Each network step
# fails loudly with its own message, so a broken build says which call failed
# instead of just exiting 1.
RUN set -eu; \
    version="${MACHINIST_VERSION}"; \
    if [ -z "$version" ] || [ "$version" = "latest" ]; then \
      effective=$(curl -fsSLS -o /dev/null -w '%{url_effective}' \
        https://github.com/owainlewis/machinist/releases/latest) \
        || { printf 'could not resolve the newest Machinist release; pass --build-arg MACHINIST_VERSION=<tag>\n' >&2; exit 1; }; \
      version=${effective##*/}; \
      printf 'MACHINIST_VERSION not set; using the newest release: %s\n' "$version" >&2; \
    fi; \
    printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+' \
      || { printf 'invalid MACHINIST_VERSION "%s": expected a release tag such as v0.4.0\n' "$version" >&2; exit 1; }; \
    curl -fsSLS -o /tmp/machinist-install.sh \
      "https://raw.githubusercontent.com/owainlewis/machinist/${version}/install.sh" \
      || { printf 'could not download install.sh for %s\n' "$version" >&2; exit 1; }; \
    env MACHINIST_VERSION="$version" MACHINIST_INSTALL_DIR=/usr/local/bin sh /tmp/machinist-install.sh; \
    rm -f /tmp/machinist-install.sh; \
    machinist version

COPY deploy/container/entrypoint.sh /usr/local/bin/machinist-entrypoint
RUN chmod 0755 /usr/local/bin/machinist-entrypoint

USER machinist
WORKDIR /home/machinist

# Informational only. The control plane UI has no authentication and its submit
# endpoint requires a loopback Origin, so it must never be routed by the Coolify
# proxy. Reach it with an SSH tunnel:
#   ssh -N -L 7331:127.0.0.1:7331 <server>
EXPOSE 7331

# Kept in the image rather than only in Compose so a plain `docker run` is
# checked too. GET /api/v1/status is intentionally unauthenticated, which makes
# it a convenient liveness probe.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:7331/api/v1/status || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/machinist-entrypoint"]
