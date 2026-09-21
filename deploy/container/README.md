# Running Machinist in a container (Coolify / Docker)

Packages the upstream Machinist release as a container for a Coolify-managed
Docker host. The repository's Go code is not modified: the entrypoint replaces
the two systemd units in `deploy/systemd/` and reuses the same configuration
files, so `scripts/setup-vm.sh` and this container remain two packagings of one
program.

Files:

- `Dockerfile` — Ubuntu image with Git, GitHub CLI, Codex, Claude Code and the
  pinned Machinist release.
- `entrypoint.sh` — supervises the control plane and the managed worker.
- `../../docker-compose.yml` — Coolify service definition using host networking.
- `../../docker-compose.bridge.yml` — alternative using bridge networking plus a
  loopback forwarder, for hosts or platforms that reject host networking.

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
3. **Never attach a domain.** The UI has no authentication, the submit endpoint
   requires a loopback browser `Origin`, and `docs/vm-deployment.md` says not to
   put it behind a public proxy. An external URL would be both unauthenticated
   and unable to submit work.

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
