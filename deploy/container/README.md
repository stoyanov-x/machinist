# Running Machinist in a container (Coolify / Docker)

Packages the upstream Machinist release as a container for a Coolify-managed
Docker host. The repository's Go code is not modified: the entrypoint replaces
the two systemd units in `deploy/systemd/` and reuses the same configuration
files, so `scripts/setup-vm.sh` and this container remain two packagings of one
program.

Files:

- `Dockerfile` — Ubuntu image with Git, GitHub CLI, Codex, Claude Code and the
  newest Machinist release.
- `entrypoint.sh` — supervises the control plane and the managed worker.
- `Caddyfile` and `proxy-entrypoint.sh` — the optional credential-gated proxy that
  publishes the UI, so an SSH tunnel is not required.
- `../../docker-compose.yml` — Coolify service definition using host networking.
- `../../docker-compose.bridge.yml` — alternative using bridge networking plus a
  loopback forwarder, for hosts or platforms that reject host networking. It also
  defines the optional proxy.

## Three constraints this packaging works around

These come from Machinist itself and shape everything else.

1. **One container, not two.** The control plane refuses any non-loopback listen
   address (`validateLoopbackListen`) and the worker refuses plain `http` to a
   non-loopback `control_plane.url`. They must share a network namespace.
   `machinist start` launches only the control plane, so the entrypoint
   supervises two sibling processes.
2. **A loopback listener is unreachable through a published port.** The control
   plane binds `127.0.0.1`, and Docker's `ports:` publishing forwards to the
   *container's* IP rather than to its loopback. The connection is accepted and
   then closed, which `curl` reports as `Empty reply from server`. Confirmed by
   control experiment: the same publish reaches a process listening on `0.0.0.0`
   correctly. There are two ways out, and both are shipped here.
3. **A domain on its own does not work.** The UI has no authentication of its own,
   the submit endpoint normally requires a loopback browser `Origin`, and
   `docs/vm-deployment.md` says not to put it behind a public proxy. Exposing it
   needs credentials *and* a way past the `Origin` check. There is one, described
   under *Exposing the UI* below.

## Choosing a networking mode

| | `docker-compose.yml` | `docker-compose.bridge.yml` |
| --- | --- | --- |
| Mechanism | `network_mode: host` | `socat` forwarder plus a published loopback port |
| Exposure risk | none: Machinist itself binds `127.0.0.1` | a `ports:` entry that drops the `127.0.0.1:` prefix exposes the unauthenticated UI |
| Works without host-networking support | no | yes |
| Testable on Docker Desktop for macOS | no — its "host" is the Linux VM | yes |

Both leave the browser on `http://127.0.0.1:<port>`, which is what the submit
endpoint's `Origin` check requires. Verified against the bridge variant:

```text
POST /api/v1/jobs   Origin: http://evil.example   -> 403 invalid submission origin or CSRF token
POST /api/v1/jobs   Origin: http://127.0.0.1:7444 -> 400 repository "nope" is not defined
```

The second response means the origin and CSRF gate passed and only the
repository lookup failed, so a tunnelled browser can submit work.

Prefer `docker-compose.yml` where Coolify accepts host networking, because it has
no exposure footgun. Fall back to `docker-compose.bridge.yml` if Coolify rejects
it — I could not test Coolify's handling of `network_mode: host`.

## Deploying on Coolify

1. Create a Docker Compose resource from this repository with the
   `docker-compose` build pack. Set the Compose file to `docker-compose.yml`, or
   to `docker-compose.bridge.yml` if Coolify rejects host networking.
2. Prefer enabling Raw Compose Deployment so Coolify does not inject networks or
   proxy labels. Never attach a domain.
3. Deploy, then reach the UI from your laptop with a tunnel to the port in use —
   `7331` for host networking, `7444` for the bridge variant:

   ```sh
   ssh -N -L 7331:127.0.0.1:7331 <server>
   ```

   Browse to the matching literal `127.0.0.1` address. A hostname or a Tailscale
   address fails the `Origin` check on submission.

`MACHINIST_CPUS` and `MACHINIST_MEMORY` are Compose variables Coolify exposes
for editing. The Machinist version is not a per-resource setting; see *Version
selection* below.

## Exposing the UI (no SSH tunnel)

The tunnel is not the only option. Machinist's `authorizeSubmission` accepts a
valid Bearer worker token *instead of* the browser `Origin`/CSRF check, so a proxy
that injects that header lets an ordinary browser on a real domain submit work.
`docker-compose.bridge.yml` ships a `caddy` service that does exactly that, behind
HTTP basic auth, and it refuses to start without credentials so an unauthenticated
admin UI cannot reach the internet by accident.

### Variables to set in Coolify

Under the resource's **Environment Variables**:

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `MACHINIST_EXPOSED` | `true` | no | `false` publishes nothing and idles the proxy |
| `MACHINIST_AUTH_USER` | – | yes | basic auth username |
| `MACHINIST_AUTH_PASSWORD_HASH` | – | yes | bcrypt hash of the password |
| `MACHINIST_TOKEN` | – | yes | the worker token (below) |
| `MACHINIST_PROXY_PORT` | `8091` | no | host port the proxy is published on, for local use |

Generate the hash, since `basic_auth` expects bcrypt:

```sh
docker run --rm --entrypoint caddy caddy:2-alpine hash-password --plaintext 'your-password'
```

Then point a Coolify domain at the **`caddy`** service on internal port **8080**,
for example `https://machinist.example.com:8080`. Coolify terminates TLS.

### Where the worker token comes from

`machinist init` generates 32 random bytes, hex-encoded to 64 characters, and
writes them to `~/.machinist/server/worker.token` in the volume. It is the same
value named by `server.worker_token_file` in `config.toml` and by
`control_plane.token_file` in `worker.toml`, so the worker already uses it.

Read it out of the running container:

```sh
docker exec -it <container> cat /home/machinist/.machinist/server/worker.token
```

**It rotates when the volume is recreated.** A fresh volume makes `init` run again
and mint a new token, so `MACHINIST_TOKEN` has to be updated to match or every
submission fails with `401 invalid worker token`.

### Verified behaviour

Measured against the bridge variant with the proxy in front:

```text
GET  /                                  no credentials -> 401  (proxy refuses)
GET  /                                  basic auth     -> 200  (the real UI)
POST /api/v1/jobs  Origin https://machinist.example.com, no CSRF -> 400 repository "nope" is not defined
POST /api/v1/jobs                       no basic auth  -> 401  (proxy refuses)
```

The `400` is the point: that request cleared the origin and CSRF gate and failed
only on the repository lookup, which is what makes a browser on a real domain
work. With `MACHINIST_EXPOSED=false` the proxy idles instead of serving.

### What you are accepting

- **Upstream advises against this.** `docs/vm-deployment.md` says not to put the
  unauthenticated UI behind a public proxy. This overrides that deliberately, with
  compensating controls. Make it a conscious decision.
- **Those credentials are effectively full admin.** They can read job history,
  prompts and repository names, and queue runs.
- **The worker token grants job submission**, which means arbitrary agent execution
  on the worker with your GitHub and model credentials. It stays in Coolify's
  environment and is injected server side; it never reaches the browser.
- **Basic auth over TLS is real but weak.** Coolify's SSO/forward-auth or an OAuth
  proxy in front would be stronger.

## First-run setup

The worker refuses to start without at least one registered repository
(`managedworker.New` requires an executor and a repository), so on a fresh volume
the entrypoint starts only the control plane and prints what to do next. Finish
setup inside the container:

```sh
docker exec -it -u machinist <container> bash
gh auth login --hostname github.com --git-protocol ssh --web
codex     # sign in once
claude    # sign in once
git clone git@github.com:<owner>/<repo>.git ~/Code/<repo>
```

Then register the clone and restart the container:

```toml
# ~/.machinist/worker.toml
[repositories.<name>]
path = "~/Code/<repo>"
```

```sh
docker restart <container>
```

Credentials, repository clones and state all live under `/home/machinist`, which
is the `machinist-home` volume, so they survive a redeploy. Logging in requires a
browser or device-code flow; Codex and Claude may try to open a browser and fail
headlessly, so use their device-code paths.

## Version skew: read this before following the README

The container installs the newest **release**, but `README.md`,
`docs/configuration.md` and `examples/config.toml` on `main` describe a newer,
unreleased design. As of writing the newest release is `v0.4.0`, and its
`machinist init` creates:

| `v0.4.0` (what you get) | `main` (what the docs say) |
| --- | --- |
| `[commands.foreman]`, `[commands.shepherd]`, `[commands.audit]` | `[commands.task-to-pr]`, `[commands.audit]` |
| `[shepherd.<repo>]` schedules with `every` / `max_actions` | `[github.repositories]` and `[triggers.*]` |

Read the docs at the tag the image actually installed
(`https://github.com/owainlewis/machinist/tree/v0.4.0/docs`). Inside the
container, `machinist version` reports the installed tag, and the entrypoint logs
it on first boot.

## Version selection, and what the upstream sync does not do

The image installs the **newest published release**. No version is stored in this
repository: leaving `MACHINIST_VERSION` unset makes the build resolve
`releases/latest`, which is precisely what upstream's `install.sh` does by
itself. The installer still verifies the archive against the published SHA-256
checksum.

The consequence is that the same commit can build a different image over time,
so a Coolify redeploy can move you onto a newer release with nothing to review.
Pin one when that matters:

```sh
docker build --build-arg MACHINIST_VERSION=v0.4.0 -f deploy/container/Dockerfile .
```

**Upgrading a release can discard run history.** Upstream documents that the move
from the `agents`/pipeline schema to `commands` "recreates the database once", so
the SQLite history under `~/.machinist/server` is reset by that upgrade.
Credentials, repository clones and configuration live elsewhere in the volume and
are unaffected. Expect it on the first upgrade past `v0.4.0`.

**The upstream sync does not deliver new Machinist features to this container.**
The image downloads a published release archive; it never compiles the source in
this repository. A daily merge of upstream `main` therefore changes this tree and
has no effect on what runs. The fork hosts these packaging files and keeps
upstream source around to diff against.

Building from source is the only way to change that: add a `golang` builder stage
and `go build ./cmd/machinist`, which needs no Node or npm stage because
`internal/controlplane/web/dist` is committed. Building at a release tag yields
the same version as downloading that release; only tracking upstream `main`
differs, and that is unreleased code carrying the schema reset described above.

## Updating

Two copies of the binary exist by design:

- `/usr/local/bin/machinist` — the pinned release baked into the image.
- `~/.local/bin/machinist` — a writable copy on the volume, seeded from the image
  on first boot, and the one `PATH` resolves to.

`machinist update` rewrites the volume copy and takes effect on the next restart.
The image copy is the fallback if an update goes wrong, and the entrypoint logs a
notice when the two versions differ. Because the volume copy wins, bumping
`.env` alone will **not** upgrade an existing volume — run
`machinist update --version <tag>` inside the container, or recreate the volume.

## Security notes

- Codex is configured upstream with `--sandbox danger-full-access`, so the agent
  executes model-authored shell commands with the container's privileges.
- The agent holds your GitHub and model credentials and has network access.
  Isolation from the host does not limit that; scope the GitHub identity instead
  (per-repository deploy keys), as `docs/vm-deployment.md` recommends.
- Run the container as the unprivileged `machinist` account, which is the image
  default. Do not add privileges, and do not mount the Docker socket.
