#!/usr/bin/env bash
#
# Supervises the Machinist control plane and its managed worker in one container.
#
# Why one container: internal/controlplane refuses any non-loopback listen
# address (validateLoopbackListen) and internal/managedworker refuses plain http
# to a non-loopback control_plane.url. Both processes therefore need the same
# network namespace. They have no parent/child relationship -- `machinist start`
# launches only the control plane -- so this script supervises two siblings.
#
# The control plane UI has no authentication and its submit endpoint requires a
# loopback Origin, so this container must never be exposed through the Coolify
# proxy. Reach the UI with:
#
#   ssh -N -L 7331:127.0.0.1:7331 <server>

set -euo pipefail

agent_home="${MACHINIST_AGENT_HOME:-/opt/agent-home}"
listen="${MACHINIST_LISTEN:-127.0.0.1:7331}"
home_dir="${HOME:?HOME must be set}"
forward_port="${MACHINIST_FORWARD_PORT:-}"

log() { printf 'machinist-entrypoint: %s\n' "$*" >&2; }

# $HOME is a volume, so anything baked into the image at that path is hidden.
# Seed the volume from the staging directory on every boot instead. `cp -n`
# never overwrites, so an existing volume is left alone.
seed_home() {
  mkdir -p "${home_dir}/.local/bin"

  if [[ -d $agent_home ]]; then
    cp -an "${agent_home}/." "${home_dir}/" 2>/dev/null || true
  fi

  if [[ ! -x "${home_dir}/.local/bin/machinist" && -x /usr/local/bin/machinist ]]; then
    # A writable, volume-backed copy so `machinist update` survives a restart.
    # /usr/local/bin keeps the pinned release as a rollback path.
    cp -a /usr/local/bin/machinist "${home_dir}/.local/bin/machinist"
    log "seeded machinist $(/usr/local/bin/machinist version 2>/dev/null || echo '') into the volume"
  elif [[ -x "${home_dir}/.local/bin/machinist" && -x /usr/local/bin/machinist ]]; then
    volume_version="$(machinist version 2>/dev/null || echo unknown)"
    image_version="$(/usr/local/bin/machinist version 2>/dev/null || echo unknown)"
    if [[ $volume_version != "$image_version" ]]; then
      log "note: volume holds machinist ${volume_version} and the image holds ${image_version}; the volume copy wins"
      log "note: run 'machinist update --version <tag>' to adopt the image version"
    fi
  fi

  # `machinist init` creates files with O_EXCL and keeps existing ones, so this
  # is idempotent and never clobbers configuration or the shared worker token.
  machinist init
}

wait_for_control_plane() {
  local host="${listen%:*}" port="${listen##*:}" attempt
  for attempt in $(seq 1 120); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$control_plane_pid" 2>/dev/null; then
      log 'control plane exited before it started listening'
      return 1
    fi
    sleep 0.5
  done
  log "control plane did not listen on ${listen} within 60s"
  return 1
}

# Alternative to host networking. Docker's port publishing forwards to the
# container's IP, so a listener bound to 127.0.0.1 inside the container is
# unreachable through a published port. This relays from the container's
# interfaces to the control plane's loopback, which makes
# `ports: 127.0.0.1:<port>:<port>` work with ordinary bridge networking.
#
# It listens on 0.0.0.0 *inside* the container, so never publish that port
# without a loopback host IP in front of it -- that would expose the
# unauthenticated UI to the network.
start_forwarder() {
  [[ -n $forward_port ]] || return 0
  if ! command -v socat >/dev/null 2>&1; then
    log 'MACHINIST_FORWARD_PORT is set but socat is missing; not forwarding'
    return 0
  fi
  log "forwarding 0.0.0.0:${forward_port} to the control plane on 127.0.0.1:${listen##*:}"
  socat "TCP-LISTEN:${forward_port},fork,reuseaddr" "TCP:127.0.0.1:${listen##*:}" &
  forwarder_pid=$!
}

shutdown() {
  local status="${1:-0}" pid
  trap - TERM INT
  log 'stopping'
  for pid in "${forwarder_pid:-}" "${worker_pid:-}" "$control_plane_pid"; do
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  exit "$status"
}

main() {
  seed_home

  log "starting control plane on ${listen}"
  machinist start --listen "$listen" &
  control_plane_pid=$!
  trap 'shutdown 0' TERM INT

  if ! wait_for_control_plane; then
    shutdown 1
  fi

  forwarder_pid=""
  start_forwarder

  worker_pid=""
  if machinist worker validate >/dev/null 2>&1; then
    log 'starting managed worker'
    machinist worker start &
    worker_pid=$!
  else
    # managedworker.New rejects a worker with no repository, so the worker stays
    # down until one is registered. Upstream's bootstrap does the same thing: it
    # only enables the worker once a repository exists.
    log 'worker not started: no repository is registered yet'
    machinist worker validate 2>&1 | sed 's/^/machinist-entrypoint:   /' >&2 || true
    log 'finish setup, then restart the container:'
    log '  docker exec -it -u machinist <container> bash'
    log '  gh auth login --hostname github.com --git-protocol ssh --web'
    log '  git clone git@github.com:<owner>/<repo>.git ~/Code/<repo>'
    log '  # then register the clone in ~/.machinist/worker.toml'
  fi

  # Exit with the failing status so the restart policy can act on it.
  local -a supervised=("$control_plane_pid")
  if [[ -n $forwarder_pid ]]; then
    supervised+=("$forwarder_pid")
  fi
  if [[ -n $worker_pid ]]; then
    supervised+=("$worker_pid")
  fi

  local exit_status=0
  set +e
  wait -n "${supervised[@]}"
  exit_status=$?
  set -e

  log "a supervised process exited (status ${exit_status}); stopping the container"
  shutdown "$exit_status"
}

main "$@"
